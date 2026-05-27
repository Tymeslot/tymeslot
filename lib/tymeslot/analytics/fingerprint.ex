defmodule Tymeslot.Analytics.Fingerprint do
  @moduledoc """
  Daily-rotated visitor fingerprint for cookie-less unique-visitor counting.

  The salt rotates every UTC day and never leaves the server. The same
  visitor on different days hashes to a different value, so no persistent
  identifier exists. This is the standard cookie-less approach used by
  Plausible and similar privacy-friendly analytics products.
  """

  @spec hash(String.t() | nil, String.t() | nil, integer() | nil) :: String.t()
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
    secret = Application.fetch_env!(:tymeslot, :analytics_salt_secret)
    Base.encode16(:crypto.hash(:sha256, day <> secret), case: :lower)
  end
end
