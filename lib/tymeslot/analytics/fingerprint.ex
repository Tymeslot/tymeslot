defmodule Tymeslot.Analytics.Fingerprint do
  @moduledoc """
  Daily-rotated visitor fingerprint for cookie-less unique-visitor counting.

  The salt rotates every UTC day and never leaves the server. The same
  visitor on different days hashes to a different value, so no persistent
  identifier exists. This is the standard cookie-less approach used by
  Plausible and similar privacy-friendly analytics products.
  """

  @doc """
  Computes a daily-rotated visitor hash from the network identity (IP +
  user agent).

  The hash deliberately excludes the meeting type: the same person is one
  visitor regardless of how many of an organizer's meeting types they
  browse, so unique-visitor counts are not inflated per page.

  When both IP and user agent are absent the network identity is unknown,
  so the hash falls back to the LiveView `session_id`. This keeps every
  recorded visit attributable to *some* visitor — a null hash would count
  toward total visits but vanish from `count(DISTINCT)` unique counts,
  making the two metrics inconsistent. Only when there is nothing to hash
  at all (no IP, no user agent, no session) does it return `nil`.

  An unresolved network identity may arrive as the sentinel string
  `"unknown"` (from `ClientIP`) or an empty string rather than `nil`. These
  are normalised to `nil` here so the session fallback engages consistently
  regardless of which form the caller passes — without this, distinct
  visitors with no resolvable IP/UA would all collapse onto a single
  `"unknown|unknown"` hash, and callers that pre-normalise would disagree
  with callers that don't, splitting one visitor's page-view and booking
  across two different join keys.
  """
  @spec hash(String.t() | nil, String.t() | nil, String.t() | nil) :: String.t() | nil
  def hash(ip, user_agent, session_id \\ nil) do
    do_hash(blank_to_nil(ip), blank_to_nil(user_agent), session_id)
  end

  defp do_hash(nil, nil, nil), do: nil

  defp do_hash(nil, nil, session_id) when is_binary(session_id) do
    build_hash(["session:" <> session_id])
  end

  defp do_hash(ip, user_agent, _session_id) do
    build_hash([to_string(ip), to_string(user_agent)])
  end

  defp blank_to_nil(value) when value in ["unknown", ""], do: nil
  defp blank_to_nil(value), do: value

  defp build_hash(parts) do
    :sha256
    |> :crypto.hash(Enum.join(parts ++ [daily_salt()], "|"))
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
