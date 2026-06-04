defmodule TymeslotWeb.Analytics do
  @moduledoc """
  Vendor-neutral client analytics bridge.

  Pushes a generic `ts:analytics` event to the connected client, which forwards
  it to whatever analytics provider is configured (currently Umami) via the JS
  facade. With no analytics script loaded (standalone Core), the client sink is a
  no-op, so this is inert outside the managed SaaS.

  Every emit is validated against `Tymeslot.Analytics.Contract` (categorical
  props only — never user ids, emails, usernames, or free text) and announced
  via a `[:tymeslot, :analytics, :emitted]` telemetry event so the test suite
  can assert coverage without any test module being referenced from here.
  """

  import Phoenix.LiveView, only: [push_event: 3]
  alias Tymeslot.Analytics.Contract
  require Logger

  @spec push(Phoenix.LiveView.Socket.t(), String.t(), map()) :: Phoenix.LiveView.Socket.t()
  def push(socket, name, props \\ %{}) when is_binary(name) and is_map(props) do
    case Contract.validate!(name, props) do
      :ok ->
        :telemetry.execute([:tymeslot, :analytics, :emitted], %{count: 1}, %{name: name})
        push_event(socket, "ts:analytics", %{name: name, props: props})

      {:error, _reason} ->
        # Non-strict mode: validation logged and signalled drop; skip emit.
        socket
    end
  rescue
    error ->
      Logger.warning("analytics push failed unexpectedly", event: name, error: inspect(error))
      socket
  end
end
