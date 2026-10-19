defmodule Tymeslot.Integrations.Calendar.OwnerActions do
  @moduledoc """
  The changes an organiser makes to one of their own connected calendars from
  the dashboard: switching it on or off, renaming it, recolouring it, ticking
  its calendars and choosing which of them block availability, letting a
  subscription count every event as busy, refreshing
  it, retrying the changes its server kept refusing, dismissing the notice
  about calendars its server stopped listing, and deleting it.

  Every function takes the acting user's id and the integration's id. It
  charges the user's budget first, then loads the integration scoped to that
  user, so an id forged in the browser reaches `{:error, :not_found}` rather
  than another organiser's calendar, and no caller can skip the budget. A
  refused budget is `{:error, {:rate_limited, message}}`, the message ready to
  show, as for creating a calendar.

  The budgets are the existing ones: the shared integration write budget for
  changes to what is synced and booked, the looser appearance budget for name
  and colour and for dismissing a notice, and the refresh budget for a refresh, which a retry of stuck
  changes is too: it asks for a sync.
  """

  alias Tymeslot.Infrastructure.Tasks
  alias Tymeslot.Integrations.Calendar.Blocking
  alias Tymeslot.Integrations.Calendar.CalDAV.OfflineQueue
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.CalendarSelectionQueries
  alias Tymeslot.Integrations.Calendar.Deletion
  alias Tymeslot.Integrations.Calendar.Management
  alias Tymeslot.Integrations.Calendar.Orchestration.Workflows
  alias Tymeslot.Integrations.Calendar.ProviderConfig
  alias Tymeslot.Integrations.Calendar.SyncSchedule
  alias Tymeslot.Integrations.Shared.InputValidators
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Workers.SyncIcsCalendarWorker

  @type refusal :: {:rate_limited, String.t()} | :not_found
  @type integration :: CalendarIntegrationSchema.t()

  # The rate limit each kind of owner action is charged to.
  @limits %{
    write: :integration_write,
    appearance: :integration_appearance,
    refresh: :calendar_refresh
  }

  # One refresh-all reaches every active calendar's provider, so the fan-out
  # is bounded, and a provider that hangs is cut off rather than holding the
  # rest of the answer.
  @refresh_concurrency 5
  @refresh_timeout_ms 30_000

  @doc """
  Switches an integration on or off, handing the primary calendar on when
  needed (see `Calendar.Management.toggle_with_primary_rebalance/1`).
  """
  @spec toggle_integration(pos_integer(), pos_integer()) ::
          {:ok, integration()} | {:error, refusal() | :duplicate_account | term()}
  def toggle_integration(user_id, integration_id) do
    with_owned(
      user_id,
      integration_id,
      :write,
      &Management.toggle_with_primary_rebalance/1
    )
  end

  @doc """
  Renames an integration to a name a person typed.

  Sanitises and length-checks it exactly as the connection form does, so a
  rename cannot store a name that could not have been created. The
  `{:error, %{name: message}}` shape is the validator's, and carries a message
  already translated for display.
  """
  @spec rename_integration(pos_integer(), pos_integer(), term(), map()) ::
          {:ok, integration()} | {:error, refusal() | Ecto.Changeset.t() | %{name: String.t()}}
  def rename_integration(user_id, integration_id, name, metadata) do
    with_owned(user_id, integration_id, :appearance, fn integration ->
      with {:ok, sanitised} <- InputValidators.validate_integration_name(name, metadata) do
        Management.update_calendar_integration(integration, %{name: sanitised})
      end
    end)
  end

  @doc """
  Sets the colour an integration's events are painted in, or clears it with
  `nil`. Nothing but the colour can be written this way.
  """
  @spec set_integration_colour(pos_integer(), pos_integer(), String.t() | nil) ::
          {:ok, integration()} | {:error, refusal() | Ecto.Changeset.t()}
  def set_integration_colour(user_id, integration_id, colour) do
    with_owned(user_id, integration_id, :appearance, fn integration ->
      Management.update_calendar_integration(integration, %{colour: colour})
    end)
  end

  @doc """
  Sets whether one of an integration's calendars is used, and whether it
  blocks availability, in one change (see `Blocking.set_state/3`).
  """
  @spec set_calendar_state(pos_integer(), pos_integer(), String.t() | integer(), Blocking.state()) ::
          {:ok, integration()}
          | {:error, refusal() | :booking_calendar | :free_busy_only | term()}
  def set_calendar_state(user_id, integration_id, calendar_id, state) do
    with_owned(user_id, integration_id, :write, &Blocking.set_state(&1, calendar_id, state))
  end

  @doc """
  Sets whether a subscription counts every event in its feed as busy, also
  those the feed marks free (see `Calendar.Management.put_all_events_busy/2`).
  Any other connection is refused with `{:error, :not_a_subscription}`.
  """
  @spec set_all_events_busy(pos_integer(), pos_integer(), boolean()) ::
          {:ok, integration()}
          | {:error, refusal() | :not_a_subscription | Ecto.Changeset.t()}
  def set_all_events_busy(user_id, integration_id, busy?) when is_boolean(busy?) do
    with_owned(
      user_id,
      integration_id,
      :write,
      &Management.put_all_events_busy(&1, busy?)
    )
  end

  @doc """
  Sets whether one of an integration's calendars is shown, leaving whether
  it blocks as it is (see `Blocking.set_shown/3`).
  """
  @spec set_calendar_shown(pos_integer(), pos_integer(), String.t() | integer(), boolean()) ::
          {:ok, integration()} | {:error, refusal() | term()}
  def set_calendar_shown(user_id, integration_id, calendar_id, shown?) do
    with_owned(user_id, integration_id, :write, &Blocking.set_shown(&1, calendar_id, shown?))
  end

  @doc """
  Sets whether one of an integration's calendars blocks availability (see
  `Blocking.set/3`). `{:error, :booking_calendar}` when asked to make a
  calendar bookings go to show only.
  """
  @spec set_calendar_blocking(pos_integer(), pos_integer(), String.t() | integer(), boolean()) ::
          {:ok, integration()} | {:error, refusal() | :booking_calendar | term()}
  def set_calendar_blocking(user_id, integration_id, calendar_id, blocks?) do
    with_owned(user_id, integration_id, :write, &Blocking.set(&1, calendar_id, blocks?))
  end

  @doc """
  Refreshes every active integration of the user, charging the refresh
  budget once. Answers each integration's name with `:ok` or
  `{:error, reason}`, in the order they are listed; one that does not answer
  in time is `{:error, :timeout}`.
  """
  @spec refresh_all_integrations(pos_integer()) ::
          {:ok, [{String.t(), :ok | {:error, term()}}]} | {:error, {:rate_limited, String.t()}}
  def refresh_all_integrations(user_id) do
    with :ok <- charge(:refresh, user_id) do
      active =
        user_id |> Management.list_calendar_integrations() |> Enum.filter(& &1.is_active)

      results =
        Tymeslot.TaskSupervisor
        |> Tasks.async_stream_nolink(active, &refresh/1,
          max_concurrency: @refresh_concurrency,
          timeout: @refresh_timeout_ms,
          on_timeout: :kill_task
        )
        |> Enum.zip_with(active, fn result, integration ->
          {integration.name, refresh_outcome(result)}
        end)

      {:ok, results}
    end
  end

  @doc """
  Deletes an integration, handing the primary calendar on when it was the
  primary (see `Tymeslot.Integrations.Calendar.Deletion`).
  """
  @spec delete_integration(pos_integer(), pos_integer()) ::
          {:ok, term()} | {:error, {:rate_limited, String.t()} | :not_found | term()}
  def delete_integration(user_id, integration_id) do
    with :ok <- charge(:write, user_id) do
      Deletion.delete_with_primary_reassignment(user_id, integration_id)
    end
  end

  # A subscription has no discoverable calendar list to refresh (discovery
  # returns the same synthetic entry every time), so refreshing one re-fetches
  # the feed instead, through the same worker the scheduled sync sweep uses; a
  # refresh already queued for it counts as success. Every other provider
  # re-runs discovery and merges the result into the selection.
  #
  # This asks about the feed family specifically, not about read-only
  # providers: `ics_url` is the only read-only provider left, but the two
  # questions are different and need not stay in step. An Exchange mailbox
  # discovers real folders and has no feed to re-fetch, so it belongs on the
  # discovery path with every other credentialed provider.
  defp refresh(%{provider: provider} = integration) do
    if ProviderConfig.subscription?(provider) do
      with {:ok, _outcome} <- SyncIcsCalendarWorker.enqueue(integration.id),
           do: {:ok, :feed_sync_enqueued}
    else
      with {:ok, _updated} <- Workflows.update_integration_with_discovery(integration),
           do: {:ok, :calendars_rediscovered}
    end
  end

  @doc """
  Puts the integration's stuck changes (those the offline queue stopped
  replaying, see `OfflineQueue.stuck_changes/1`) back in the queue and asks
  for a sync to replay them. Answers how many changes were retried.
  """
  @spec retry_stuck_changes(pos_integer(), pos_integer()) ::
          {:ok, non_neg_integer()} | {:error, refusal() | term()}
  def retry_stuck_changes(user_id, integration_id) do
    with_owned(user_id, integration_id, :refresh, fn integration ->
      released = OfflineQueue.release_stuck(integration.id)

      with {:ok, _job} <- SyncSchedule.request_sync(integration), do: {:ok, released}
    end)
  end

  @doc """
  Dismisses the notice about calendars the server stopped listing, for the
  entries in `shown_ids`: those the owner was shown. One recorded after the
  notice was rendered stays, so the owner sees it before it can go.
  """
  @spec dismiss_removed_calendars(pos_integer(), pos_integer(), [String.t()]) ::
          {:ok, boolean()} | {:error, refusal() | Ecto.Changeset.t()}
  def dismiss_removed_calendars(user_id, integration_id, shown_ids) do
    with_owned(user_id, integration_id, :appearance, fn integration ->
      CalendarSelectionQueries.dismiss_removed_calendars(integration, shown_ids)
    end)
  end

  defp refresh_outcome({:ok, {:ok, _done}}), do: :ok
  defp refresh_outcome({:ok, {:error, reason}}), do: {:error, reason}
  defp refresh_outcome({:exit, :timeout}), do: {:error, :timeout}
  defp refresh_outcome({:exit, reason}), do: {:error, {:exit, reason}}

  defp with_owned(user_id, integration_id, bucket, fun) do
    with :ok <- charge(bucket, user_id),
         {:ok, integration} <-
           Management.get_calendar_integration(integration_id, user_id) do
      fun.(integration)
    end
  end

  defp charge(bucket, user_id) do
    case RateLimiter.check(Map.fetch!(@limits, bucket), user_id) do
      :ok -> :ok
      {:error, :rate_limited, message} -> {:error, {:rate_limited, message}}
      # Not a user any row could belong to.
      {:error, :invalid_user_id} -> {:error, :not_found}
    end
  end
end
