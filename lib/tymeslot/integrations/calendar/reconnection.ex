defmodule Tymeslot.Integrations.Calendar.Reconnection do
  @moduledoc """
  Business logic for reconnecting an existing CalDAV-family calendar
  integration without destroying its calendar selections.

  Two branches:

  - `:password_only` — url and username are unchanged. The caller updates
    just the credentials and keeps the existing calendar list and primary
    status.

  - `:account_change` — url or username changed. The caller re-runs
    discovery and asks the user to pick calendars again.

  Top-level entry points are `reconnect/3` (test + branch dispatch) and
  `finalise_account_change/3` (second step for the account-change branch).
  """

  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.Calendar.CalDAV.Provider, as: CalDAVProvider
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Providers.CaldavCommon
  alias Tymeslot.Integrations.Calendar.Shared.ErrorHandler
  alias Tymeslot.Integrations.Calendar.Shared.PathUtils
  alias Tymeslot.Integrations.CalendarManagement

  @type integration :: CalendarIntegrationSchema.t()
  @type params :: %{optional(String.t()) => term()}
  @type change_kind :: :password_only | :account_change

  @type reconnect_ok ::
          {:ok, :updated, integration()}
          | {:ok, :needs_calendar_selection, %{calendars: [map()], credentials: map()}}

  @type reconnect_error ::
          {:error, :invalid_credentials}
          | {:error, {:changeset, Ecto.Changeset.t()}}
          | {:error, term()}

  @doc """
  Returns whether the proposed url/username constitute a password-only
  rotation or a full account change. Accepts a decrypted integration struct
  (virtual `username` populated).
  """
  @spec credentials_change_kind(integration(), params()) :: change_kind()
  def credentials_change_kind(%CalendarIntegrationSchema{} = integration, params) do
    new_url = params |> Map.get("url") |> to_string() |> PathUtils.normalize_base_url()
    current_url = PathUtils.normalize_base_url(integration.base_url || "")

    new_username = params |> Map.get("username", "") |> to_string() |> String.trim()
    current_username = integration.username |> to_string() |> String.trim()

    if new_url == current_url and new_username == current_username do
      :password_only
    else
      :account_change
    end
  end

  @doc """
  Reconnect an existing CalDAV-family integration.

  Options (keyword):
    * `:test_connection` — `(params -> :ok | {:error, term()})`. Defaults to a
      real CalDAV probe via `CaldavCommon.test_connection/2`, which preserves
      atom error reasons (e.g. `:unauthorized`) needed for credential-error
      detection.
    * `:discover` — `(provider, url, username, password -> {:ok, %{calendars: …, discovery_credentials: …}} | {:error, term()})`.
      Defaults to `Calendar.discover_and_filter_calendars/4`.
  """
  @spec reconnect(integration(), params(), keyword()) :: reconnect_ok() | reconnect_error()
  def reconnect(%CalendarIntegrationSchema{} = integration, params, opts \\ []) do
    test_connection = Keyword.get(opts, :test_connection, &default_test_connection/1)
    discover = Keyword.get(opts, :discover, &Calendar.discover_and_filter_calendars/4)

    case credentials_change_kind(integration, params) do
      :password_only ->
        case test_connection.(params) do
          :ok -> apply_password_only(integration, params)
          {:error, :unauthorized} -> {:error, :invalid_credentials}
          {:error, reason} -> {:error, reason}
        end

      :account_change ->
        apply_account_change(integration, params, discover)
    end
  end

  @doc """
  Second step for the `:account_change` branch: persist the new URL,
  credentials, and calendar selection after the user has picked calendars.
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
        path = cal["path"] || cal[:path]
        Map.put(cal, "selected", path in selected_paths)
      end)

    attrs = %{
      base_url:
        creds
        |> Map.get(:url)
        |> to_string()
        |> PathUtils.normalize_base_url(),
      username: Map.get(creds, :username),
      password: Map.get(creds, :password),
      calendar_paths: Enum.filter(selected_paths, &is_binary/1),
      calendar_list: calendar_list
    }

    case CalendarManagement.update_calendar_integration(integration, attrs) do
      {:ok, updated} -> {:ok, updated}
      {:error, %Ecto.Changeset{} = cs} -> {:error, {:changeset, cs}}
    end
  end

  # Probes the CalDAV server with the supplied credentials and returns
  # atom-based error reasons so the caller can distinguish `:unauthorized`
  # from generic failures. Goes through `CaldavCommon.test_connection` which
  # preserves raw atoms rather than the string-formatted errors produced by
  # the higher-level `Calendar.discover_and_filter_calendars` pipeline.
  defp default_test_connection(params) do
    client =
      CalDAVProvider.new(%{
        base_url: Map.get(params, "url"),
        username: Map.get(params, "username"),
        password: Map.get(params, "password")
      })

    case CaldavCommon.test_connection(client) do
      {:ok, _message} -> :ok
      {:error, :unauthorized} -> {:error, :unauthorized}
      {:error, reason} -> {:error, reason}
    end
  end

  defp apply_password_only(integration, params) do
    attrs = %{
      base_url: params |> Map.get("url") |> to_string() |> PathUtils.normalize_base_url(),
      username: Map.get(params, "username"),
      password: Map.get(params, "password")
    }

    case CalendarManagement.update_calendar_integration(integration, attrs) do
      {:ok, updated} -> {:ok, :updated, updated}
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

      {:error, reason} when is_binary(reason) ->
        if ErrorHandler.categorize_error(reason) == :auth do
          {:error, :invalid_credentials}
        else
          {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
