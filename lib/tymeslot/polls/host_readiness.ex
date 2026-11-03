defmodule Tymeslot.Polls.HostReadiness do
  @moduledoc """
  What a host needs before a poll's links go out: a calendar connected, so
  the voting page is open, and a username, so the links have somewhere to
  point. Checked when a poll is created and before every write that emails a
  participant.
  """

  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Profiles

  @doc """
  `:ok` when the host has a bookable calendar connected.

  Guests vote on the public page, which opens only once the host has a
  calendar connected (`Tymeslot.Scheduling.LinkAccessPolicy`). A poll
  created, or an invitation sent, before then hands out a link nobody can
  use, so both wait for the calendar the dashboard asks them to connect.
  """
  @spec ensure_calendar(integer()) :: :ok | {:error, :no_calendar}
  def ensure_calendar(user_id) do
    if Calendar.has_bookable_integration?(user_id), do: :ok, else: {:error, :no_calendar}
  end

  @doc """
  `:ok` when nobody is to be emailed (`recipients` is empty) or the host has
  a username.

  Every email to a participant carries a link under the host's username, and
  one sent without it is discarded (`Tymeslot.Notifications.Email.PollEmails`)
  after the invitation has been counted against the host's limits. Refused up
  front instead, when anyone is to be emailed.
  """
  @spec ensure_username(integer(), list()) :: :ok | {:error, :no_username}
  def ensure_username(_user_id, []), do: :ok

  def ensure_username(user_id, _recipients) do
    case Profiles.get_profile(user_id) do
      %{username: username} when is_binary(username) -> :ok
      _profile -> {:error, :no_username}
    end
  end
end
