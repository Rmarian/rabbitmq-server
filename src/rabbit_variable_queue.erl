%%   The contents of this file are subject to the Mozilla Public License
%%   Version 1.1 (the "License"); you may not use this file except in
%%   compliance with the License. You may obtain a copy of the License at
%%   http://www.mozilla.org/MPL/
%%
%%   Software distributed under the License is distributed on an "AS IS"
%%   basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%%   License for the specific language governing rights and limitations
%%   under the License.
%%
%%   The Original Code is RabbitMQ.
%%
%%   The Initial Developers of the Original Code are LShift Ltd,
%%   Cohesive Financial Technologies LLC, and Rabbit Technologies Ltd.
%%
%%   Portions created before 22-Nov-2008 00:00:00 GMT by LShift Ltd,
%%   Cohesive Financial Technologies LLC, or Rabbit Technologies Ltd
%%   are Copyright (C) 2007-2008 LShift Ltd, Cohesive Financial
%%   Technologies LLC, and Rabbit Technologies Ltd.
%%
%%   Portions created by LShift Ltd are Copyright (C) 2007-2009 LShift
%%   Ltd. Portions created by Cohesive Financial Technologies LLC are
%%   Copyright (C) 2007-2009 Cohesive Financial Technologies
%%   LLC. Portions created by Rabbit Technologies Ltd are Copyright
%%   (C) 2007-2009 Rabbit Technologies Ltd.
%%
%%   All Rights Reserved.
%%
%%   Contributor(s): ______________________________________.
%%

-module(rabbit_variable_queue).

-export([init/1, in/3, set_queue_ram_duration_target/2, remeasure_egress_rate/1,
         out/1]).

-record(vqstate,
        { q1,
          q2,
          gamma,
          q3,
          q4,
          target_ram_msg_count,
          ram_msg_count,
          queue,
          index_state,
          next_seq_id,
          out_counter,
          egress_rate,
          avg_egress_rate,
          egress_rate_timestamp,
          prefetcher
        }).

-record(alpha,
        { msg,
          seq_id,
          is_delivered,
          msg_on_disk,
          index_on_disk
        }).

-record(beta,
        { msg_id,
          seq_id,
          is_persistent,
          is_delivered,
          index_on_disk
        }).

-record(gamma,
        { seq_id,
          count
        }).

-include("rabbit.hrl").

%% Basic premise is that msgs move from q1 -> q2 -> gamma -> q3 -> q4
%% but they can only do so in the right form. q1 and q4 only hold
%% alphas (msgs in ram), q2 and q3 only hold betas (msg on disk, index
%% in ram), and gamma is just a count of the number of index entries
%% on disk at that stage (msg on disk, index on disk).
%%
%% When a msg arrives, we decide in which form it should be. It is
%% then added to the rightmost appropriate queue, maintaining
%% order. Thus if the msg is to be an alpha, it will be added to q1,
%% unless all of q1, q2, gamma and q3 are empty, in which case it will
%% go to q4. If it is to be a beta, it will be added to q2 unless all
%% of q2 and gamma are empty, in which case it will go to q3.
%%
%% The major invariant is that if the msg is to be a beta, q1 will be
%% empty, and if it is to be a gamma then both q1 and q2 will be empty.
%%
%% When taking msgs out of the queue, if q4 is empty then we drain the
%% prefetcher. If that doesn't help then we read directly from q3, or
%% gamma, if q3 is empty. If q3 and gamma are empty then we have an
%% invariant that q2 must be empty because q2 can only grow if gamma
%% is non empty.
%%
%% A further invariant is that if the queue is non empty, either q4 or
%% q3 contains at least one entry. I.e. we never allow gamma to
%% contain all msgs in the queue.  Also, if q4 is non empty and gamma
%% is non empty then q3 must be non empty.

init(QueueName) ->
    {LowSeqId, NextSeqId, Count, IndexState} =
        rabbit_queue_index:init(QueueName),
    Gamma = case Count of
                0 -> #gamma { seq_id = undefined, count = 0 };
                _ -> #gamma { seq_id = LowSeqId, count = Count }
            end,
    #vqstate { q1 = queue:new(), q2 = queue:new(),
               gamma = Gamma,
               q3 = queue:new(), q4 = queue:new(),
               target_ram_msg_count = undefined,
               ram_msg_count = 0,
               queue = QueueName,
               index_state = IndexState,
               next_seq_id = NextSeqId,
               out_counter = 0,
               egress_rate = 0,
               avg_egress_rate = 0,
               egress_rate_timestamp = now(),
               prefetcher = undefined
             }.

in(Msg, IsDelivered, State = #vqstate { next_seq_id = SeqId }) ->
    in(test_keep_msg_in_ram(SeqId, State), Msg, SeqId, IsDelivered,
       State #vqstate { next_seq_id = SeqId + 1 }).

in(msg, Msg = #basic_message { guid = MsgId,
                               is_persistent = IsPersistent },
   SeqId, IsDelivered, State = #vqstate { index_state = IndexState,
                                          ram_msg_count = RamMsgCount }) ->
    MsgOnDisk = maybe_write_msg_to_disk(false, Msg),
    {IndexOnDisk, IndexState1} =
        maybe_write_index_to_disk(false, IsPersistent, MsgId, SeqId,
                                  IsDelivered, IndexState),
    Entry = #alpha { msg = Msg, seq_id = SeqId, is_delivered = IsDelivered,
                     msg_on_disk = MsgOnDisk, index_on_disk = IndexOnDisk },
    State1 = State #vqstate { ram_msg_count = RamMsgCount + 1,
                              index_state = IndexState1 },
    store_alpha_entry(Entry, State1);

in(index, Msg = #basic_message { guid = MsgId,
                                 is_persistent = IsPersistent },
   SeqId, IsDelivered, State = #vqstate { index_state = IndexState,
                                          q1 = Q1 }) ->
    true = maybe_write_msg_to_disk(true, Msg),
    {IndexOnDisk, IndexState1} =
        maybe_write_index_to_disk(false, IsPersistent, MsgId, SeqId,
                                  IsDelivered, IndexState),
    Entry = #beta { msg_id = MsgId, seq_id = SeqId, is_delivered = IsDelivered,
                    is_persistent = IsPersistent, index_on_disk = IndexOnDisk },
    State1 = State #vqstate { index_state = IndexState1 },
    true = queue:is_empty(Q1), %% ASSERTION
    store_beta_entry(Entry, State1);

in(neither, Msg = #basic_message { guid = MsgId,
                                   is_persistent = IsPersistent },
   SeqId, IsDelivered, State = #vqstate { index_state = IndexState,
                                          q1 = Q1, q2 = Q2, gamma = Gamma }) ->
    true = maybe_write_msg_to_disk(true, Msg),
    {true, IndexState1} =
        maybe_write_index_to_disk(true, IsPersistent, MsgId, SeqId,
                                  IsDelivered, IndexState),
    true = queue:is_empty(Q1) andalso queue:is_empty(Q2), %% ASSERTION
    %% gamma may be empty, seq_id > next_segment_boundary from q3
    %% head, so we need to find where the segment boundary is before
    %% or equal to seq_id
    GammaSeqId = rabbit_queue_index:next_segment_boundary(SeqId) -
        rabbit_queue_index:segment_size(),
    Gamma1 = #gamma { seq_id = GammaSeqId, count = 1 },
    State #vqstate { index_state = IndexState1,
                     gamma = combine_gammas(Gamma, Gamma1) }.

set_queue_ram_duration_target(
  DurationTarget, State = #vqstate { avg_egress_rate = EgressRate,
                                     target_ram_msg_count = TargetRamMsgCount
                                   }) ->
    TargetRamMsgCount1 = trunc(DurationTarget * EgressRate), %% msgs = sec * msgs/sec
    State1 = State #vqstate { target_ram_msg_count = TargetRamMsgCount1 },
    if TargetRamMsgCount == TargetRamMsgCount1 ->
            State1;
       TargetRamMsgCount < TargetRamMsgCount1 ->
            maybe_start_prefetcher(State1);
       true ->
            reduce_memory_use(State1)
    end.

remeasure_egress_rate(State = #vqstate { egress_rate = OldEgressRate,
                                         egress_rate_timestamp = Timestamp,
                                         out_counter = OutCount }) ->
    %% We do an average over the last two values, but also hold the
    %% current value separately so that the average always only
    %% incorporates the last two values, and not the current value and
    %% the last average. Averaging helps smooth out spikes.
    Now = now(),
    EgressRate = OutCount / timer:now_diff(Now, Timestamp),
    AvgEgressRate = (EgressRate + OldEgressRate) / 2,
    State #vqstate { egress_rate = EgressRate,
                     avg_egress_rate = AvgEgressRate,
                     egress_rate_timestamp = Now,
                     out_counter = 0 }.

out(State =
    #vqstate { q4 = Q4,
               out_counter = OutCount, prefetcher = Prefetcher,
               index_state = IndexState }) ->
    case queue:out(Q4) of
        {empty, _Q4} when Prefetcher == undefined ->
            out_from_q3(State);
        {empty, _Q4} ->
            Q4a =
                case rabbit_queue_prefetcher:drain_and_stop(Prefetcher) of
                    empty -> Q4;
                    Q4b -> Q4b
                end,
            out(State #vqstate { q4 = Q4a, prefetcher = undefined });
        {{value,
          #alpha { msg = Msg = #basic_message { guid = MsgId }, seq_id = SeqId,
                   is_delivered = IsDelivered, msg_on_disk = MsgOnDisk,
                   index_on_disk = IndexOnDisk }}, Q4a} ->
            IndexState1 =
                case IndexOnDisk andalso not IsDelivered of
                    true ->
                        rabbit_queue_index:write_delivered(SeqId, IndexState);
                    false ->
                        IndexState
                end,
            AckTag = case {IndexOnDisk, MsgOnDisk} of
                         {true,  true } -> {ack_index_and_store, MsgId, SeqId};
                         {false, true } -> {ack_store, MsgId};
                         {false, false} -> ack_not_on_disk
                     end,
            {{Msg, IsDelivered, AckTag},
             State #vqstate { q4 = Q4a, out_counter = OutCount + 1,
                              index_state = IndexState1 }}
    end.

out_from_q3(State = #vqstate { q1 = Q1, q2 = Q2, index_state = IndexState,
                               gamma = #gamma { seq_id = GammaSeqId,
                                                count = GammaCount},
                               q3 = Q3, q4 = Q4 }) ->
    case queue:out(Q3) of
        {empty, _Q3} ->
            0 = GammaCount, %% ASSERTION
            true = queue:is_empty(Q2), %% ASSERTION
            true = queue:is_empty(Q1), %% ASSERTION
            {empty, State};
        {{value,
          #beta { msg_id = MsgId, seq_id = SeqId, is_delivered = IsDelivered,
                  is_persistent = IsPersistent, index_on_disk = IndexOnDisk }},
         Q3a} ->
            {ok, Msg = #basic_message { is_persistent = IsPersistent,
                                        guid = MsgId }} =
                rabbit_msg_store:read(MsgId),
            Q4a = queue:in(
                    #alpha { msg = Msg, seq_id = SeqId,
                             is_delivered = IsDelivered, msg_on_disk = true,
                             index_on_disk = IndexOnDisk }, Q4),
            %% TODO - if it's not persistent, remove it from disk now
            State1 = State #vqstate { q3 = Q3a, q4 = Q4a },
            State2 =
                case {queue:is_empty(Q3a), 0 == GammaCount} of
                    {true, true} ->
                        %% q3 is now empty, it wasn't before; gamma is
                        %% still empty. So q2 must be empty, and q1
                        %% can now be joined onto q4
                        true = queue:is_empty(Q2), %% ASSERTION
                        State1 #vqstate { q1 = queue:new(),
                                          q4 = queue:join(Q4a, Q1) };
                    {true, false} ->
                        {List, IndexState1, Gamma1SeqId} =
                            read_index_segment(GammaSeqId, IndexState),
                        State3 = State1 #vqstate { index_state = IndexState1 },
                        %% length(List) may be < segment_size because
                        %% of acks. But it can't be []
                        Q3b = betas_from_segment_entries(List),
                        case GammaCount - length(List) of
                            0 ->
                                %% gamma is now empty, but it wasn't
                                %% before, so can now join q2 onto q3
                                State3 #vqstate {
                                  gamma = #gamma { seq_id = undefined,
                                                   count = 0 },
                                  q2 = queue:new(), q3 = queue:join(Q3b, Q2) };
                            N when N > 0 ->
                                State3 #vqstate {
                                  gamma = #gamma { seq_id = Gamma1SeqId,
                                                   count = N }, q3 = Q3b }
                        end;
                    {false, _} ->
                        %% q3 still isn't empty, we've not touched
                        %% gamma, so the invariants between q1, q2,
                        %% gamma and q3 are maintained
                        State1
                end,
            out(State2)
    end.

betas_from_segment_entries(List) ->
    queue:from_list(lists:map(fun ({MsgId, SeqId, IsPersistent, IsDelivered}) ->
                                      #beta { msg_id = MsgId, seq_id = SeqId,
                                              is_persistent = IsPersistent,
                                              is_delivered = IsDelivered,
                                              index_on_disk = true }
                              end, List)).

read_index_segment(SeqId, IndexState) ->
    SeqId1 = SeqId + rabbit_queue_index:segment_size(),
    case rabbit_queue_index:read_segment_entries(SeqId, IndexState) of
        {[], IndexState1} -> read_index_segment(SeqId1, IndexState1);
        {List, IndexState1} -> {List, IndexState1, SeqId1}
    end.

maybe_start_prefetcher(State) ->
    %% TODO
    State.

reduce_memory_use(State = #vqstate { ram_msg_count = RamMsgCount,
                                     target_ram_msg_count = TargetRamMsgCount })
  when TargetRamMsgCount >= RamMsgCount ->
    State;
reduce_memory_use(State =
                  #vqstate { target_ram_msg_count = TargetRamMsgCount }) ->
    State1 = maybe_push_q4_to_betas(maybe_push_q1_to_betas(State)),
    case TargetRamMsgCount of
        0 -> push_betas_to_gammas(State1);
        _ -> State1
    end.

maybe_write_msg_to_disk(Bool, Msg = #basic_message {
                                guid = MsgId, is_persistent = IsPersistent })
  when Bool orelse IsPersistent ->
    ok = rabbit_msg_store:write(MsgId, ensure_binary_properties(Msg)),
    true;
maybe_write_msg_to_disk(_Bool, _Msg) ->
    false.

maybe_write_index_to_disk(Bool, IsPersistent, MsgId, SeqId, IsDelivered,
                          IndexState) when Bool orelse IsPersistent ->
    IndexState1 = rabbit_queue_index:write_published(
                    MsgId, SeqId, IsPersistent, IndexState),
    {true, case IsDelivered of
               true  -> rabbit_queue_index:write_delivered(SeqId, IndexState1);
               false -> IndexState1
           end};
maybe_write_index_to_disk(_Bool, _IsPersistent, _MsgId, _SeqId, _IsDelivered,
                          IndexState) ->
    {false, IndexState}.

test_keep_msg_in_ram(SeqId, #vqstate { target_ram_msg_count = TargetRamMsgCount,
                                       ram_msg_count = RamMsgCount,
                                       q1 = Q1, q3 = Q3 }) ->
    case TargetRamMsgCount of
        undefined ->
            msg;
        0 ->
            case queue:out(Q3) of
                {empty, _Q3} ->
                    %% if TargetRamMsgCount == 0, we know we have no
                    %% alphas. If q3 is empty then gamma must be empty
                    %% too, so create a beta, which should end up in
                    %% q3
                    index;
                {{value, #beta { seq_id = OldSeqId }}, _Q3a} ->
                    %% don't look at the current gamma as it may be empty
                    case SeqId >= rabbit_queue_index:next_segment_boundary(OldSeqId) of
                        true -> neither;
                        false -> index
                    end
            end;
        _ when TargetRamMsgCount > RamMsgCount ->
                     msg;
        _         -> case queue:is_empty(Q1) of
                         true -> index;
                         false -> msg %% can push out elders to disk
                     end
    end.

ensure_binary_properties(Msg = #basic_message { content = Content }) ->
    Msg #basic_message {
      content = rabbit_binary_parser:clear_decoded_content(
                  rabbit_binary_generator:ensure_content_encoded(Content)) }.

store_alpha_entry(Entry = #alpha {}, State =
                  #vqstate { q1 = Q1, q2 = Q2,
                             gamma = #gamma { count = GammaCount },
                             q3 = Q3, q4 = Q4 }) ->
    case queue:is_empty(Q1) andalso queue:is_empty(Q2) andalso 
        GammaCount == 0 andalso queue:is_empty(Q3) of
        true ->
            State #vqstate { q4 = queue:in(Entry, Q4) };
        false ->
            maybe_push_q1_to_betas(State #vqstate { q1 = queue:in(Entry, Q1) })
    end.

store_beta_entry(Entry = #beta {}, State =
                 #vqstate { q2 = Q2, gamma = #gamma { count = GammaCount },
                            q3 = Q3 }) ->
    case queue:is_empty(Q2) andalso GammaCount == 0 of
        true  -> State #vqstate { q3 = queue:in(Entry, Q3) };
        false -> State #vqstate { q2 = queue:in(Entry, Q2) }
    end.

maybe_push_q1_to_betas(State = #vqstate { q1 = Q1 }) ->
    maybe_push_alphas_to_betas(
      fun queue:out/1,
      fun (Beta, Q1a, State1) ->
              %% these could legally go to q3 if gamma and q2 are empty
              store_beta_entry(Beta, State1 #vqstate { q1 = Q1a })
      end, Q1, State).

maybe_push_q4_to_betas(State = #vqstate { q4 = Q4 }) ->
    maybe_push_alphas_to_betas(
      fun queue:out_r/1,
      fun (Beta, Q4a, State1 = #vqstate { q3 = Q3 }) ->
              %% these must go to q3
              State1 #vqstate { q3 = queue:in_r(Beta, Q3), q4 = Q4a }
      end, Q4, State).

maybe_push_alphas_to_betas(_Generator, _Consumer, _Q, State =
                           #vqstate { ram_msg_count = RamMsgCount,
                                      target_ram_msg_count = TargetRamMsgCount })
  when TargetRamMsgCount >= RamMsgCount ->
    State;
maybe_push_alphas_to_betas(Generator, Consumer, Q, State =
                           #vqstate { ram_msg_count = RamMsgCount }) ->
    case Generator(Q) of
        {empty, _Q} -> State;
        {{value,
          #alpha { msg = Msg = #basic_message { guid = MsgId,
                                                is_persistent = IsPersistent },
                   seq_id = SeqId, is_delivered = IsDelivered,
                   msg_on_disk = MsgOnDisk, index_on_disk = IndexOnDisk }},
         Qa} ->
            true = case MsgOnDisk of
                       true -> true;
                       false -> maybe_write_msg_to_disk(true, Msg)
                   end,
            Beta = #beta { msg_id = MsgId, seq_id = SeqId,
                           is_persistent = IsPersistent,
                           is_delivered = IsDelivered,
                           index_on_disk = IndexOnDisk },
            State1 = State #vqstate { ram_msg_count = RamMsgCount - 1 },
            maybe_push_alphas_to_betas(Generator, Consumer, Qa,
                                       Consumer(Beta, Qa, State1))
    end.

push_betas_to_gammas(State = #vqstate { q2 = Q2, gamma = Gamma, q3 = Q3,
                                        index_state = IndexState }) ->
    %% HighSeqId is high in the sense that it must be higher than the
    %% seq_id in Gamma, but it's also the lowest of the betas that we
    %% transfer from q2 to gamma.
    {HighSeqId, Len1, Q2a, IndexState1} =
        push_betas_to_gammas(fun queue:out/1, undefined, Q2, IndexState),
    Gamma1 = #gamma { seq_id = Gamma1SeqId } =
        combine_gammas(Gamma, #gamma { seq_id = HighSeqId, count = Len1 }),
    State1 = State #vqstate { q2 = Q2a, gamma = Gamma1,
                              index_state = IndexState1 },
    case queue:out(Q3) of
        {empty, _Q3} -> State1;
        {{value, #beta { seq_id = SeqId }}, _Q3a} -> 
            Limit = rabbit_queue_index:next_segment_boundary(SeqId),
            case Gamma1SeqId of
                Limit -> %% already only holding the minimum, nothing to do
                    State1;
                _ when Gamma1SeqId == undefined orelse
                (is_integer(Gamma1SeqId) andalso Gamma1SeqId > Limit) ->
                    %% ASSERTION (sadly large!)
                    %% This says that if Gamma1SeqId /= undefined then
                    %% the gap from Limit to Gamma1SeqId is an integer
                    %% multiple of segment_size
                    0 = case Gamma1SeqId of
                            undefined -> 0;
                            _ -> (Gamma1SeqId - Limit) rem
                                     rabbit_queue_index:segment_size()
                        end,
                    %% LowSeqId is low in the sense that it must be
                    %% lower than the seq_id in gamma1, in fact either
                    %% gamma1 has undefined as its seq_id or there
                    %% does not exist a seq_id X s.t. X > LowSeqId and
                    %% X < gamma1's seq_id (would be +1 if it wasn't
                    %% for the possibility of gaps in the seq_ids).
                    %% But because we use queue:out_r, LowSeqId is
                    %% actually also the highest seq_id of the betas we
                    %% transfer from q3 to gammas.
                    {LowSeqId, Len2, Q3b, IndexState2} =
                        push_betas_to_gammas(fun queue:out_r/1, Limit, Q3,
                                             IndexState1),
                    true = Gamma1SeqId > LowSeqId, %% ASSERTION
                    Gamma2 = combine_gammas(
                               #gamma { seq_id = Limit, count = Len2}, Gamma1),
                    State1 #vqstate { q3 = Q3b, gamma = Gamma2,
                                      index_state = IndexState2 }
            end
    end.

push_betas_to_gammas(Generator, Limit, Q, IndexState) ->
    case Generator(Q) of
        {empty, Qa} -> {undefined, 0, Qa, IndexState};
        {{value, #beta { seq_id = SeqId }}, _Qa} ->
            {Count, Qb, IndexState1} =
                push_betas_to_gammas(Generator, Limit, Q, 0, IndexState),
            {SeqId, Count, Qb, IndexState1}
    end.

push_betas_to_gammas(Generator, Limit, Q, Count, IndexState) ->
    case Generator(Q) of
        {empty, Qa} -> {Count, Qa, IndexState};
        {{value, #beta { seq_id = SeqId }}, _Qa}
        when Limit /= undefined andalso SeqId < Limit ->
            {Count, Q, IndexState};
        {{value, #beta { msg_id = MsgId, seq_id = SeqId,
                         is_persistent = IsPersistent,
                         is_delivered = IsDelivered,
                         index_on_disk = IndexOnDisk}}, Qa} ->
            IndexState1 =
                case IndexOnDisk of
                    true -> IndexState;
                    false ->
                        {true, IndexState2} =
                            maybe_write_index_to_disk(
                              true, IsPersistent, MsgId,
                              SeqId, IsDelivered, IndexState),
                        IndexState2
                end,
            push_betas_to_gammas(Generator, Limit, Qa, Count + 1, IndexState1)
    end.

%% the first arg is the older gamma            
combine_gammas(#gamma { count = 0 }, #gamma { count = 0 }) -> {undefined, 0};
combine_gammas(#gamma { count = 0 }, #gamma {       } = B) -> B;
combine_gammas(#gamma {       } = A, #gamma { count = 0 }) -> A;
combine_gammas(#gamma { seq_id = SeqIdLow,  count = CountLow },
               #gamma { seq_id = SeqIdHigh, count = CountHigh}) ->
    true = SeqIdLow + CountLow =< SeqIdHigh, %% ASSERTION
    %% note the above assertion does not say ==. This is because acks
    %% may mean that the counts are not straight multiples of
    %% segment_size.
    #gamma { seq_id = SeqIdLow, count = CountLow + CountHigh}.
