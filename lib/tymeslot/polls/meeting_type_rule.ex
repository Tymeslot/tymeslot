defmodule Tymeslot.Polls.MeetingTypeRule do
  @moduledoc """
  Which of the host's meeting types a poll may take: not a paid type, since
  confirming a poll takes no payment, nor a one-off event, which is a single
  dated session rather than a kind of meeting.

  The one rule creating a poll, editing one, and listing the types the
  dashboard offers all apply.
  """

  alias Tymeslot.MeetingTypes

  @type error :: :meeting_type_not_found | :payment_required_type

  @doc """
  Loads the meeting type `id` scoped to `user_id` and holds it to `check/1`.
  A type that is not the user's is `{:error, :meeting_type_not_found}`.
  """
  @spec fetch(integer(), integer()) :: {:ok, Ecto.Schema.t()} | {:error, error()}
  def fetch(id, user_id) do
    case MeetingTypes.get_meeting_type(id, user_id) do
      nil -> {:error, :meeting_type_not_found}
      meeting_type -> check(meeting_type)
    end
  end

  @doc "Whether a poll may take `meeting_type`."
  @spec check(Ecto.Schema.t()) :: {:ok, Ecto.Schema.t()} | {:error, error()}
  def check(%{payment_required: true}), do: {:error, :payment_required_type}
  def check(%{one_off: true}), do: {:error, :meeting_type_not_found}
  def check(meeting_type), do: {:ok, meeting_type}
end
