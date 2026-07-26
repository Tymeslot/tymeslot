defmodule Tymeslot.Security.RateLimiter.Integrations do
  @moduledoc false

  require Logger

  alias Tymeslot.Security.RateLimiter.Helpers

  @connection_test_limit 20
  @connection_test_window_ms 600_000

  @typedoc """
  Who a connection test is charged to.

  Connection-test buckets must be partitioned by the actor, never collapsed into
  one instance-wide bucket: interactive tests are charged to the user who
  clicked, scheduled health probes to the integration they probe, so background
  probing can never exhaust a real user's budget (and vice versa). `:host` is
  the fallback for callers with no actor context — still a real partition, so
  there is no shared bucket to starve.
  """
  @type connection_scope ::
          {:user, pos_integer()} | {:integration, pos_integer()} | {:host, String.t()}

  @spec check_caldav_connection(connection_scope() | term()) ::
          :ok | {:error, :rate_limited, String.t()}
  def check_caldav_connection(scope),
    do: check_connection_test("caldav_connection", "CalDAV connection test", scope)

  @spec check_mirotalk_connection(connection_scope() | term()) ::
          :ok | {:error, :rate_limited, String.t()}
  def check_mirotalk_connection(scope),
    do: check_connection_test("mirotalk_connection", "MiroTalk connection test", scope)

  @spec check_nextcloud_connection(connection_scope() | term()) ::
          :ok | {:error, :rate_limited, String.t()}
  def check_nextcloud_connection(scope),
    do: check_connection_test("nextcloud_connection", "Nextcloud connection test", scope)

  @spec check_calendar_discovery(String.t()) :: :ok | {:error, :rate_limited, String.t()}
  def check_calendar_discovery(ip) do
    Helpers.check_with_logging(
      "calendar_discovery:#{ip}",
      30,
      600_000,
      "calendar discovery",
      ip
    )
  end

  defp check_connection_test(bucket, operation, scope) do
    case scope_key(scope) do
      {:ok, key} ->
        Helpers.check_with_logging(
          "#{bucket}:#{key}",
          @connection_test_limit,
          @connection_test_window_ms,
          operation,
          key
        )

      :error ->
        Logger.error("Unattributable connection test",
          operation: operation,
          scope: inspect(scope)
        )

        {:error, :rate_limited,
         "Connection test could not be attributed to an account. Please try again."}
    end
  end

  defp scope_key({:user, user_id}) when is_integer(user_id) and user_id > 0,
    do: {:ok, "user:#{user_id}"}

  defp scope_key({:integration, id}) when is_integer(id) and id > 0,
    do: {:ok, "integration:#{id}"}

  defp scope_key({:host, host}) when is_binary(host) and host != "", do: {:ok, "host:#{host}"}
  defp scope_key(_scope), do: :error
end
