defmodule Tymeslot.Emails.Shared.PollHost do
  @moduledoc """
  The host of a poll as its participant emails present them: the name they
  are sent from and the address replies go to. Expects the poll's `user` and
  its `profile` preloaded.
  """

  alias Tymeslot.Emails.Shared.MjmlEmail
  alias Tymeslot.Polls.PollSchema
  alias Tymeslot.Profiles
  alias Tymeslot.Profiles.ProfileSchema

  @spec display_name(PollSchema.t()) :: String.t()
  def display_name(%PollSchema{user: %{profile: %ProfileSchema{} = profile}}) do
    case Profiles.display_name(profile) do
      name when is_binary(name) -> name
      nil -> MjmlEmail.fetch_from_name()
    end
  end

  def display_name(%PollSchema{user: %{name: name}}) when is_binary(name) and name != "",
    do: name

  def display_name(_poll), do: MjmlEmail.fetch_from_name()

  @spec email(PollSchema.t()) :: String.t() | nil
  def email(%PollSchema{user: %{email: email}}), do: email
  def email(_poll), do: nil
end
