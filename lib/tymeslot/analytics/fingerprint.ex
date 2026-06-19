defmodule Tymeslot.Analytics.Fingerprint do
  @moduledoc """
  Daily-rotated visitor fingerprint for cookie-less unique-visitor counting.

  The salt rotates every UTC day and never leaves the server. The same
  visitor on different days hashes to a different value, so no persistent
  identifier exists. This is the standard cookie-less approach used by
  Plausible and similar privacy-friendly analytics products.
  """

  @spec hash(String.t() | nil, String.t() | nil, integer() | nil) :: String.t() | nil
  def hash(nil, nil, _meeting_type_id), do: nil

  def hash(ip, user_agent, meeting_type_id) do
    inputs = [
      to_string(ip || ""),
      to_string(user_agent || ""),
      to_string(meeting_type_id || 0),
      daily_salt()
    ]

    :sha256
    |> :crypto.hash(Enum.join(inputs, "|"))
    |> Base.encode16(case: :lower)
  end

  defp daily_salt do
    day = Date.to_iso8601(Date.utc_today())
    secret = Application.get_env(:tymeslot, :analytics_salt_secret) || dev_fallback_salt()
    Base.encode16(:crypto.hash(:sha256, day <> secret), case: :lower)
  end

  # Returns a process-lifetime random salt for environments that have not
  # configured `analytics_salt_secret` (e.g. early-boot before runtime.exs
  # is loaded). Stored in `:persistent_term` so it is stable within a node
  # restart but never survives a crash — intentionally weak outside production.
  defp dev_fallback_salt do
    case :persistent_term.get({__MODULE__, :dev_salt}, nil) do
      nil ->
        salt = Base.encode64(:crypto.strong_rand_bytes(32))
        :persistent_term.put({__MODULE__, :dev_salt}, salt)
        salt

      existing ->
        existing
    end
  end
end
