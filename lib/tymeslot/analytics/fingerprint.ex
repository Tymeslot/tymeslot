defmodule Tymeslot.Analytics.Fingerprint do
  @moduledoc """
  Daily-rotated visitor fingerprint for cookie-less unique-visitor counting.

  Each UTC day gets its own random salt, stored in `analytics_salts` so that
  every node hashes with the same one, and deleted by
  `Tymeslot.Workers.DataRetentionWorker` once the day is over. The same
  visitor on different days hashes to a different value, so no persistent
  identifier exists. This is the standard cookie-less approach used by
  Plausible and similar privacy-friendly analytics products.

  The salt is random rather than derived from the date and a secret, because a
  derived salt can be rebuilt for any past day, and with it a stored hash can be
  brute-forced back to the visitor's IP address (there are only about four
  billion IPv4 addresses). Once a day's salt is deleted, that day's hashes can
  no longer be recomputed from anything.
  """

  alias Tymeslot.Analytics.SaltQueries
  alias Tymeslot.Clock

  @salt_cache_key {__MODULE__, :daily_salt}

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

  # Today's salt, cached per node with the date it belongs to. A cache miss (a
  # new day, or a fresh node) reads the shared row, creating it if this is the
  # day's first hash anywhere, so every node hashes with the same salt.
  defp daily_salt do
    today = Clock.utc_today()

    case :persistent_term.get(@salt_cache_key, nil) do
      {^today, salt} ->
        salt

      _stale_or_missing ->
        salt = SaltQueries.get_or_create(today)
        :persistent_term.put(@salt_cache_key, {today, salt})
        salt
    end
  end
end
