defmodule Tymeslot.Integrations.Calendar.Reconnection do
  @moduledoc """
  Business logic for reconnecting an existing CalDAV-family calendar
  integration.

  Reconnect is a unified two-phase flow regardless of whether the user is
  rotating a password, swapping accounts, or coming back to add previously
  unselected calendars:

  1. `reconnect/3` runs discovery against the supplied credentials and
     returns `{:ok, :needs_calendar_selection, payload}`. Discovery
     implicitly validates the credentials.
  2. `finalise_account_change/3` persists the new credentials and the
     calendar selection chosen by the user.

  The caller is responsible for pre-ticking the user's existing selections
  (typically `integration.calendar_paths`) in the picker UI so a same-
  account reconnect keeps the prior choices unless the user changes them.
  """

  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.Calendar.CalendarEntry
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Selection
  alias Tymeslot.Integrations.Calendar.Shared.PathUtils
  alias Tymeslot.Integrations.CalendarManagement

  @type integration :: CalendarIntegrationSchema.t()
  @type params :: %{optional(String.t()) => term()}

  @type reconnect_ok ::
          {:ok, :needs_calendar_selection, %{calendars: [map()], credentials: map()}}

  @type reconnect_error ::
          {:error, :invalid_credentials}
          | {:error, {:changeset, Ecto.Changeset.t()}}
          | {:error, term()}

  @doc """
  Reconnect an existing CalDAV-family integration.

  Always runs discovery against the supplied credentials and returns the
  full list of calendars so the caller can prompt the user to confirm or
  adjust their selection. Discovery implicitly validates credentials —
  an auth failure surfaces as `{:error, :invalid_credentials}`.

  Options (keyword):
    * `:discover` — `(provider, url, username, password -> {:ok, %{calendars: …, discovery_credentials: …}} | {:error, term()})`.
      Defaults to `Calendar.discover_and_filter_calendars/5`, closed over this
      integration's owner so the discovery is charged to them. The seam stays
      arity-4 so callers injecting a double need not know about the actor.
  """
  @spec reconnect(integration(), params(), keyword()) :: reconnect_ok() | reconnect_error()
  def reconnect(%CalendarIntegrationSchema{} = integration, params, opts \\ []) do
    default_discover = fn provider, url, username, password ->
      Calendar.discover_and_filter_calendars(
        provider,
        url,
        username,
        password,
        integration.user_id
      )
    end

    discover = Keyword.get(opts, :discover, default_discover)
    apply_account_change(integration, params, discover)
  end

  @doc """
  Persist the new URL, credentials, and calendar selection picked by the
  user. Returns `{:error, :no_calendars_selected}` if the selection is
  empty.
  """
  @spec finalise_account_change(integration(), map(), [String.t()]) ::
          {:ok, integration()}
          | {:error, :no_calendars_selected}
          | {:error, {:changeset, Ecto.Changeset.t()}}
  def finalise_account_change(%CalendarIntegrationSchema{} = integration, payload, selected_paths) do
    valid_paths = Enum.filter(selected_paths, fn p -> is_binary(p) and p != "" end)

    if valid_paths == [] do
      {:error, :no_calendars_selected}
    else
      do_finalise_account_change(integration, payload, valid_paths)
    end
  end

  defp do_finalise_account_change(
         %CalendarIntegrationSchema{} = integration,
         payload,
         selected_paths
       ) do
    %{credentials: creds, calendars: calendars} = payload

    calendar_list =
      Enum.map(calendars, fn cal ->
        entry = CalendarEntry.normalize(cal)
        %{entry | selected: entry.path in selected_paths}
      end)

    credential_attrs = %{
      base_url:
        creds
        |> Map.get(:url)
        |> to_string()
        |> PathUtils.normalize_base_url(),
      username: Map.get(creds, :username),
      password: Map.get(creds, :password)
    }

    attrs = Map.merge(credential_attrs, Selection.calendar_list_attrs(calendar_list))

    case CalendarManagement.update_calendar_integration(integration, attrs) do
      {:ok, updated} -> {:ok, updated}
      {:error, %Ecto.Changeset{} = cs} -> {:error, {:changeset, cs}}
    end
  end

  defp apply_account_change(%CalendarIntegrationSchema{provider: provider}, params, discover) do
    case discover.(
           provider,
           Map.get(params, "url"),
           Map.get(params, "username"),
           Map.get(params, "password")
         ) do
      {:ok, %{calendars: calendars, discovery_credentials: credentials}} ->
        {:ok, :needs_calendar_selection, %{calendars: calendars, credentials: credentials}}

      # Discovery hands back `{category, message}`, with the category derived
      # from the raw provider error before the message was localised. Branch
      # on the category only: `message` is display text and, once translated,
      # carries no English keywords left to match on.
      {:error, {:auth, _message}} ->
        {:error, :invalid_credentials}

      {:error, {_category, message}} when is_binary(message) ->
        {:error, message}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
