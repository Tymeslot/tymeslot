defmodule Tymeslot.Auth.AccountDeletion.Policy do
  @moduledoc """
  The rules a deletion request follows, read from configuration:

    * `config :tymeslot, :account_deletion_grace_days` (default `0`): days
      between the request and the deletion. With `0` the deletion job is due
      at once, so the account goes as soon as the job runs.
    * `config :tymeslot, :collect_deletion_feedback` (default `false`): whether
      the deletion dialog asks why the user is leaving. Core stores nothing;
      the answer goes to the account-deletion hook.

  Both are read at call time: they are consulted once per request, never in
  a hot path.
  """

  alias Tymeslot.Profiles

  @feedback_reasons ~w(too_expensive missing_features hard_to_use switched_tool no_longer_needed technical_problems other)
  @comment_max_length 500

  @doc "Days between a deletion request and the deletion."
  @spec grace_days() :: non_neg_integer()
  def grace_days do
    case Application.get_env(:tymeslot, :account_deletion_grace_days, 0) do
      days when is_integer(days) and days > 0 -> days
      _zero_or_invalid -> 0
    end
  end

  @doc "Whether a request deletes the account straight away."
  @spec immediate?() :: boolean()
  def immediate?, do: grace_days() == 0

  @doc "When an account asked to be deleted at `now` is to be deleted."
  @spec scheduled_at(DateTime.t()) :: DateTime.t()
  def scheduled_at(%DateTime{} = now), do: DateTime.add(now, grace_days(), :day)

  @doc """
  The calendar date of `at` in `timezone`, so a deletion date reads as the
  user's own day. A missing or unknown timezone falls back to UTC.
  """
  @spec local_date(DateTime.t(), String.t() | nil) :: Date.t()
  def local_date(%DateTime{} = at, timezone) when is_binary(timezone) do
    case DateTime.shift_zone(at, timezone) do
      {:ok, shifted} -> DateTime.to_date(shifted)
      {:error, _reason} -> DateTime.to_date(at)
    end
  end

  def local_date(%DateTime{} = at, _no_timezone), do: DateTime.to_date(at)

  @doc """
  `local_date/2` in the user's own zone (`user_timezone/1`): the default
  zone for a profile with none, or with one the time-zone database does not
  know.
  """
  @spec user_local_date(DateTime.t(), integer()) :: Date.t()
  def user_local_date(%DateTime{} = at, user_id), do: local_date(at, user_timezone(user_id))

  @doc "The user's own clock, by the owner-zone rule (`Profiles.timezone/1`)."
  @spec user_timezone(integer()) :: String.t()
  def user_timezone(user_id), do: Profiles.get_user_timezone(user_id)

  @doc "Whether the deletion dialog asks for exit feedback."
  @spec collect_feedback?() :: boolean()
  def collect_feedback?,
    do: Application.get_env(:tymeslot, :collect_deletion_feedback, false) == true

  @doc "The reasons the dialog offers, as stored values."
  @spec feedback_reasons() :: [String.t()]
  def feedback_reasons, do: @feedback_reasons

  @doc """
  How the account holder proves it is them: an account with a password hash
  types its password; one without (it signs in through a provider only) types
  its email address. The hash, not the provider, decides: an account created
  through a provider can set a password later, and an "email" account always
  has one.
  """
  @spec confirmation_method(%{
          required(:password_hash) => String.t() | nil,
          optional(atom()) => term()
        }) :: :password | :email
  def confirmation_method(%{password_hash: hash}) when is_binary(hash) and hash != "",
    do: :password

  def confirmation_method(_user), do: :email

  @doc """
  The exit feedback in `params` (string keys `"reason"`, `"comment"`), or
  `nil` when collection is off or no known reason was chosen. A comment is
  trimmed, stripped of null bytes and capped at #{@comment_max_length}
  characters; blank becomes `nil`.
  """
  @spec normalise_feedback(map()) :: Tymeslot.Auth.Behaviours.AccountDeletionHook.feedback()
  def normalise_feedback(params) when is_map(params) do
    with true <- collect_feedback?(),
         reason when reason in @feedback_reasons <- params["reason"] do
      %{reason: reason, comment: normalise_comment(params["comment"])}
    else
      _no_feedback -> nil
    end
  end

  defp normalise_comment(comment) when is_binary(comment) do
    trimmed =
      comment
      |> String.replace("\x00", "")
      |> String.trim()
      |> String.slice(0, @comment_max_length)

    if trimmed == "", do: nil, else: trimmed
  end

  defp normalise_comment(_missing), do: nil
end
