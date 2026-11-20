defmodule Tymeslot.Factory.PollFactories do
  @moduledoc """
  The poll factories (polls, time slots, participants and votes), mixed into
  `Tymeslot.Factory` with `use`. Call them through `Tymeslot.Factory`:
  `insert(:poll_participant, poll: poll)`.
  """

  defmacro __using__(_opts) do
    quote do
      alias Tymeslot.Factory.TokenHash
      alias Tymeslot.Polls.PollParticipantSchema
      alias Tymeslot.Polls.PollSchema
      alias Tymeslot.Polls.PollTimeSlotSchema
      alias Tymeslot.Polls.PollVoteSchema
      alias Tymeslot.Security.Token

      @spec poll_factory(map()) :: Tymeslot.Polls.PollSchema.t()
      def poll_factory(attrs) do
        %PollSchema{
          title: "Team sync",
          duration_minutes: 30,
          timezone: "Etc/UTC",
          status: :open,
          token: Token.generate(24),
          user: build(:user)
        }
        |> merge_attributes(attrs)
        |> evaluate_lazy_attributes()
        |> TokenHash.put(:token, :token_hash)
      end

      @spec poll_time_slot_factory() :: Tymeslot.Polls.PollTimeSlotSchema.t()
      def poll_time_slot_factory do
        start_time = DateTime.utc_now() |> DateTime.add(1, :day) |> DateTime.truncate(:second)
        end_time = DateTime.add(start_time, 1, :hour)

        %PollTimeSlotSchema{
          start_time: start_time,
          end_time: end_time,
          position: sequence(:poll_slot_position, & &1),
          poll: build(:poll)
        }
      end

      # Someone the host invited, unless the test says otherwise: confirmed at once
      # and still owing a vote, which is the participant nearly every test wants.
      # The app confirms anyone else only when they vote, so a confirmed
      # participant always has `invited_at` or `voted_at`:
      #
      #   * `confirmed_at: nil` (with a `link_sent_at`) is a pending link request,
      #     never invited either;
      #   * `invited_at: nil` with a `voted_at` is someone who asked for their link
      #     and voted;
      #   * `invited_at: nil` alone is a participant from before confirmation, whom
      #     the confirmation migration confirmed without a vote. Only legacy rows
      #     have that shape; say so where a test builds one.
      @spec poll_participant_factory(map()) :: Tymeslot.Polls.PollParticipantSchema.t()
      def poll_participant_factory(attrs) do
        confirmed_at = Map.get(attrs, :confirmed_at, DateTime.utc_now(:second))

        %PollParticipantSchema{
          name: sequence(:poll_participant_name, &"Participant #{&1}"),
          email: sequence(:poll_participant_email, &"participant#{&1}@example.com"),
          token: Token.generate(24),
          locale: "en",
          confirmed_at: confirmed_at,
          invited_at: confirmed_at,
          poll: build(:poll)
        }
        |> merge_attributes(attrs)
        |> evaluate_lazy_attributes()
        |> TokenHash.put(:token, :token_hash)
      end

      @spec poll_vote_factory() :: Tymeslot.Polls.PollVoteSchema.t()
      def poll_vote_factory do
        %PollVoteSchema{
          response: :yes,
          participant: build(:poll_participant),
          time_slot: build(:poll_time_slot)
        }
      end
    end
  end
end
