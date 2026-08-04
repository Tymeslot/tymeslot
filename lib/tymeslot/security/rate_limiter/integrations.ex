defmodule Tymeslot.Security.RateLimiter.Integrations do
  @moduledoc false

  require Logger

  alias Tymeslot.Security.RateLimiter.Helpers

  @connection_test_limit 20
  @connection_test_window_ms 600_000

  # The custom video provider and ICS subscriptions both probe an arbitrary
  # user-supplied host (raw URL, redirects followed), unlike the other buckets
  # which only ever reach a server the operator configured. Give them the
  # tightest budget of the bunch, over the same window as everything else.
  @arbitrary_host_connection_test_limit 5

  # Unchanged from when discovery was keyed on an IP — only the key changed,
  # so the budget a single actor gets stays what it always was. Discovery
  # shares `@connection_test_window_ms` with every other bucket (the two
  # windows happened to already be identical), just its own tighter-than-some
  # limit.
  @discovery_limit 30

  @typedoc """
  Who a connection test is charged to.

  Always `{:user, user_id}` — the user who clicked "Test connection" or is
  setting up an integration. Never one instance-wide bucket: the actor is
  always required, a caller with no actor context is a bug at the call site,
  not a case to fall back to a shared bucket for. A scheduled background
  health probe never reaches this function at all — it is unmetered by
  construction, see `Tymeslot.Integrations.Shared.ConnectionProbe`'s
  `:background` clause — so there is no competing "integration" actor here.
  """
  @type connection_scope :: {:user, pos_integer()}

  @typedoc """
  The connection-test bucket a provider draws its budget from. `:discovery`
  is calendar discovery, folded in here rather than kept as a separate
  function — it is metered exactly like a connection test (per-actor,
  same window), it just isn't tied to any one provider's own bucket.
  """
  @type connection_bucket ::
          :caldav | :nextcloud | :mirotalk | :custom | :ics_url | :oauth | :discovery

  @doc """
  Rate limit a provider's connection-test attempts, in the bucket it draws
  its budget from. The bucket key string and operation label for each
  bucket are resolved here, in the one place that has to know them.
  """
  @spec check_connection_test(connection_bucket(), connection_scope() | nil) ::
          :ok | {:error, :rate_limited, String.t()} | {:error, :unattributable}
  def check_connection_test(bucket, scope) do
    {bucket_key, operation} = bucket_info(bucket)

    case scope_key(scope) do
      {:ok, key} ->
        Helpers.check_with_logging(
          "#{bucket_key}:#{key}",
          bucket_limit(bucket),
          @connection_test_window_ms,
          operation,
          key
        )

      :error ->
        Logger.error("Unattributable connection test",
          operation: operation,
          scope: inspect(scope)
        )

        # Nothing downstream reads a message for this refusal — `ConnectionProbe`
        # deliberately never invents user-facing text for `:unattributable`
        # either (see its moduledoc); building that copy is the caller's job.
        {:error, :unattributable}
    end
  end

  defp bucket_info(:caldav), do: {"caldav_connection", "CalDAV connection test"}
  defp bucket_info(:nextcloud), do: {"nextcloud_connection", "Nextcloud connection test"}
  defp bucket_info(:mirotalk), do: {"mirotalk_connection", "MiroTalk connection test"}
  defp bucket_info(:custom), do: {"custom_video_connection", "Custom video connection test"}
  defp bucket_info(:ics_url), do: {"ics_url_connection", "Calendar subscription test"}
  defp bucket_info(:oauth), do: {"oauth_connection", "OAuth connection test"}
  defp bucket_info(:discovery), do: {"calendar_discovery", "calendar discovery"}

  defp bucket_limit(:custom), do: @arbitrary_host_connection_test_limit
  defp bucket_limit(:ics_url), do: @arbitrary_host_connection_test_limit
  defp bucket_limit(:discovery), do: @discovery_limit
  defp bucket_limit(_bucket), do: @connection_test_limit

  defp scope_key({:user, user_id}) when is_integer(user_id) and user_id > 0,
    do: {:ok, "user:#{user_id}"}

  defp scope_key(_scope), do: :error
end
