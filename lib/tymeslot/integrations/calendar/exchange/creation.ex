defmodule Tymeslot.Integrations.Calendar.Exchange.Creation do
  @moduledoc """
  Validates and creates a read-only Exchange (EWS) calendar integration.

  A sibling of `Tymeslot.Integrations.Calendar.Creation` rather than another
  branch inside it, for the same reason the subscription path is separate: an
  EWS integration is not CalDAV-shaped. It has no `calendar_paths` — an
  Exchange folder is named by the opaque `FolderId` the server issues — and it
  carries two fields the CalDAV attrs do not: `provider_account_email`, the
  mailbox `GetUserAvailability` is addressed to, and `verify_ssl`, which an
  on-premises server behind a self-signed certificate needs.

  Every discovered folder is persisted `read_only: true`. The provider refuses
  writes, and `Exchange.FolderDiscovery` deliberately does not set the flag
  itself: `FindFolder` reports no rights, so claiming one would assert
  something the server never said, and the module's doc names *the point where
  the write path is offered* as where the property belongs. This is that
  point. Without it an Exchange folder would be eligible as the user's default
  booking calendar, and every booking written to it would fail.
  """

  alias Tymeslot.Integrations.Calendar.CalendarEntry
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Connection
  alias Tymeslot.Integrations.Calendar.InputValidation, as: CalendarInputValidation
  alias Tymeslot.Integrations.Calendar.Shared.ErrorHandler
  alias Tymeslot.Integrations.CalendarManagement
  alias Tymeslot.Workers.SyncExchangeCalendarWorker

  require Logger

  @type user_id :: pos_integer()

  @doc """
  Validates and creates a read-only Exchange (EWS) integration.

  Returns the same result shapes as
  `Tymeslot.Integrations.Calendar.Creation.create_with_validation/3`.
  """
  @spec create_with_validation(user_id(), %{String.t() => term()}, keyword()) ::
          {:ok, CalendarIntegrationSchema.t()}
          | {:error,
             {:form_errors, %{String.t() => term()}}
             | {:changeset, Ecto.Changeset.t()}
             | {:rate_limited, String.t()}
             | :unattributable
             | :duplicate_integration}
  def create_with_validation(user_id, params, opts \\ [])
      when is_integer(user_id) and is_map(params) do
    metadata = Keyword.get(opts, :metadata, %{})

    # Deliberately no `Creation.ensure_primary_on_first/3`, for the reason the
    # subscription path omits it too: it promotes the user's first integration
    # unconditionally, through `CalendarPrimary` directly rather than through
    # `PrimarySelection.maybe_set_as_primary/1`, so its read-only guard never
    # runs. An Exchange mailbox can never receive a booking, and promoting one
    # would leave a user whose only calendar is Exchange with a primary that
    # fails every booking write.
    with {:ok, sanitized} <-
           CalendarInputValidation.validate_exchange_form(params, metadata: metadata),
         :ok <- check_no_duplicate(user_id, sanitized),
         attrs <- attrs(user_id, sanitized, params),
         {:ok, attrs} <- probe(attrs, user_id),
         {:ok, integration} <- CalendarManagement.create_calendar_integration(attrs) do
      enqueue_initial_sync(integration)
      {:ok, integration}
    else
      error -> normalise_error(error)
    end
  end

  # The tagged refusals pass straight up: building display copy for a
  # rate-limit or attribution failure is the web layer's job, not this step's.
  defp normalise_error({:error, %Ecto.Changeset{} = changeset}),
    do: {:error, {:changeset, changeset}}

  defp normalise_error({:error, errors}) when is_map(errors), do: {:error, {:form_errors, errors}}
  defp normalise_error({:error, _reason} = error), do: error

  # Same `base_url||username` shape the CalDAV-family dedup uses, so one
  # mailbox cannot be connected twice through the same endpoint.
  defp check_no_duplicate(user_id, %{"url" => url, "username" => username}) do
    case CalendarIntegrationQueries.get_any_by_account_for_user(
           user_id,
           "exchange",
           account_id(url, username)
         ) do
      {:ok, _existing} -> {:error, :duplicate_integration}
      {:error, :not_found} -> :ok
    end
  end

  defp account_id(url, username), do: "#{url}||#{username}"

  defp attrs(user_id, sanitized, params) do
    %{
      "name" => name,
      "url" => url,
      "username" => username,
      "password" => password,
      "mailbox" => mailbox
    } = sanitized

    %{
      user_id: user_id,
      name: name,
      provider: "exchange",
      base_url: url,
      username: username,
      password: password,
      provider_account_id: account_id(url, username),
      provider_account_email: mailbox,
      verify_ssl: verify_ssl?(params),
      # No paths: an EWS folder has none. The selection lives entirely in
      # `calendar_list`, keyed by `FolderId`.
      calendar_paths: [],
      calendar_list: calendar_list(params),
      is_active: true
    }
  end

  @doc """
  Reads the connection form's TLS-verification checkbox.

  Public because the form's two steps both need the answer and must not
  disagree: discovery runs before this module does, and has to hand the same
  setting to the transport that the row will later carry.

  An unchecked HTML checkbox submits nothing at all, so an absent key means
  "unticked" rather than "not asked". The form pairs the checkbox with a hidden
  `"false"` so the two cases cannot be confused, but the absent case is handled
  here rather than trusted to the markup.
  """
  @spec verify_ssl?(map()) :: boolean()
  def verify_ssl?(params), do: params["verify_ssl"] in ["true", true]

  defp calendar_list(params) do
    params
    |> Map.get("calendar_list", [])
    |> List.wrap()
    |> Enum.map(fn calendar ->
      entry = calendar |> CalendarEntry.normalize() |> CalendarEntry.with_defaults()
      %{entry | selected: true, read_only: true}
    end)
  end

  # The same live probe the CalDAV-family creation runs, through the same
  # rate-limited choke point, so a mistyped endpoint or credential is reported
  # on the form rather than discovered by the first sync an hour later.
  defp probe(attrs, user_id) do
    config = Map.take(attrs, [:base_url, :username, :password, :verify_ssl])

    case Connection.probe(:exchange, config, {:user, user_id}) do
      {:ok, _message} ->
        {:ok, attrs}

      # The choke point's own two refusals travel untouched, because the web
      # layer owns their display copy (see `ConnectionProbe`'s moduledoc).
      {:error, :unattributable} ->
        {:error, :unattributable}

      {:error, {:rate_limited, _message} = refusal} ->
        {:error, refusal}

      # Everything else is reported form-level against `:discovery`: a probe
      # failure is never attributable to one input. The message is passed
      # through rather than sanitised, because
      # `Exchange.Provider.perform_connection_test/1` has already run it
      # through `ErrorHandler` and answers a localised sentence. Sanitising a
      # second time re-enters the `is_binary` branch, which pattern-matches on
      # substrings like "401" that the sentence no longer contains, and so
      # collapses "Authentication failed. Please check your credentials." into
      # the generic "An error occurred" catch-all.
      {:error, message} when is_binary(message) ->
        {:error, %{discovery: message}}

      {:error, reason} ->
        {:error, %{discovery: ErrorHandler.sanitize_error_message(reason, :exchange)}}
    end
  end

  # A fresh Exchange integration contributes no busy time until its scheduled
  # sync first runs, while already showing as connected. Enqueueing closes that
  # gap; a failure to enqueue is non-fatal, since the fallback sweep will still
  # pick the integration up.
  defp enqueue_initial_sync(integration) do
    case %{"calendar_integration_id" => integration.id}
         |> SyncExchangeCalendarWorker.new()
         |> Oban.insert() do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to enqueue initial Exchange sync",
          calendar_integration_id: integration.id,
          error: inspect(reason)
        )

        :ok
    end
  end
end
