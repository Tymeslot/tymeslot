defmodule Tymeslot.Integrations.Calendar.CalDAV.FamilyProvider do
  @moduledoc """
  The provider module of a CalDAV-family member that adds nothing to the
  shared CalDAV implementation but its wording.

      use Tymeslot.Integrations.Calendar.CalDAV.FamilyProvider,
        member: :radicale,
        schema: [
          base_url: "Radicale server URL (e.g., https://radicale.example.com:5232)",
          username: "Radicale username",
          password: "Radicale password",
          calendar_paths: "List of calendar UUIDs to sync (auto-discovered if not provided)"
        ],
        invalid_url_message: dgettext("integrations_calendar", "Invalid Radicale URL. ..."),
        connected_message: dgettext("integrations_calendar", "Radicale connection successful"),
        not_found_message: dgettext("integrations_calendar", "Radicale server not found. ...")

  Everything else comes from the member's row in `CalDAV.Family` (its display
  name and any fixed server address) or is the same for every member. The
  three messages are expressions evaluated on each call, so they translate
  into the caller's locale; the using module declares
  `use Gettext, backend: TymeslotWeb.Gettext` for them, ahead of this `use`.

  A failed connection test is worded by `ErrorHandler.sanitize_error_message/2`.

  Nextcloud and generic CalDAV add behaviour of their own (login flow, server
  detection) and stay hand-written.
  """

  # This module references nothing outside the generated code, so the
  # members' compile-time dependency on it pulls in no other module: the
  # callbacks' shared bodies live in `FamilyProvider.Callbacks`, called at
  # runtime.

  @schema_keys [:base_url, :username, :password, :calendar_paths]

  defmacro __using__(opts) do
    member = Keyword.fetch!(opts, :member)
    descriptions = Keyword.fetch!(opts, :schema)

    unless Keyword.keys(descriptions) == @schema_keys,
      do: raise(ArgumentError, ":schema describes exactly #{inspect(@schema_keys)}, in order")

    quote do
      @behaviour Tymeslot.Integrations.Calendar.Provider

      alias Tymeslot.Integrations.Calendar.CalDAV.EventProcessor
      alias Tymeslot.Integrations.Calendar.CalDAV.Family
      alias Tymeslot.Integrations.Calendar.CalDAV.FamilyProvider.Callbacks
      alias Tymeslot.Integrations.Calendar.CalendarEntry
      alias Tymeslot.Integrations.Calendar.Provider
      alias Tymeslot.Integrations.Calendar.Providers.CaldavCommon
      alias Tymeslot.Integrations.Calendar.Shared.{ErrorHandler, ProviderCommon}

      @impl Provider
      def provider_type, do: unquote(member)

      @impl Provider
      def display_name, do: Family.display_name(unquote(member))

      @impl Provider
      def connection_test_bucket, do: :caldav

      @doc "Returns the component module that renders the CalDAV-family configuration form"
      @spec setup_component() :: module()
      def setup_component,
        do: TymeslotWeb.Components.Dashboard.Integrations.Calendar.CaldavFamilyConfig

      @impl Provider
      def config_schema, do: Callbacks.config_schema(unquote(member), unquote(descriptions))

      @impl Provider
      def validate_config(config),
        do:
          Callbacks.validate_config(
            unquote(member),
            config,
            unquote(Keyword.fetch!(opts, :invalid_url_message))
          )

      @impl Provider
      def new(config), do: Callbacks.new(unquote(member), config)

      @doc """
      Tests the connection to the server, with this provider's wording.
      """
      @impl Provider
      @spec perform_connection_test(map()) :: {:ok, String.t()} | {:error, term()}
      def perform_connection_test(integration) do
        ProviderCommon.test_caldav_provider_connection(integration,
          success_message: unquote(Keyword.fetch!(opts, :connected_message)),
          not_found_message: unquote(Keyword.fetch!(opts, :not_found_message)),
          error_formatter: &format_error/1
        )
      end

      @doc """
      Discovers the calendars available on the account.
      """
      @impl Provider
      @spec discover_calendars(map()) ::
              {:ok, [CalendarEntry.t()]}
              | {:error, Tymeslot.Integrations.Calendar.CalDAV.Base.error_reason()}
      def discover_calendars(client) do
        # The provider picks the discovery paths to try.
        client
        |> Map.put(:provider, unquote(member))
        |> CaldavCommon.discover_calendars()
      end

      @impl Provider
      def discover_calendars_for_integration(integration),
        do: ProviderCommon.caldav_discover_from_integration(__MODULE__, integration)

      @impl Provider
      defdelegate build_client_configs(integration),
        to: ProviderCommon,
        as: :caldav_build_client_configs

      @impl Provider
      defdelegate build_booking_client_config(integration),
        to: ProviderCommon,
        as: :caldav_build_booking_client_config

      @impl Provider
      defdelegate create_event(client, event_data), to: CaldavCommon

      @impl Provider
      defdelegate update_event(client, uid, event_data), to: CaldavCommon

      @impl Provider
      defdelegate delete_event(client, uid, opts), to: CaldavCommon

      @impl Provider
      defdelegate fetch_event(client, event_ref), to: CaldavCommon

      @impl Provider
      defdelegate find_moved_event(client, event_ref), to: CaldavCommon

      @impl Provider
      defdelegate list_events(client, opts), to: CaldavCommon

      @impl Provider
      def list_events_representation, do: :raw

      @impl Provider
      def convert_events(events), do: events

      @impl Provider
      defdelegate normalise_events(raw_events, context), to: EventProcessor

      @impl Provider
      defdelegate check_connectivity(client), to: CaldavCommon

      defp format_error(error), do: ErrorHandler.sanitize_error_message(error, unquote(member))
    end
  end
end
