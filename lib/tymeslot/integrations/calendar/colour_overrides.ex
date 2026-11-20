defmodule Tymeslot.Integrations.Calendar.ColourOverrides do
  @moduledoc """
  A user's durable per-event colour overrides: setting and clearing one on a
  Tymeslot meeting or an external calendar event, looking them up, and
  resolving which palette key an event is displayed in.

  `Tymeslot.Integrations.Calendar` delegates to this module; the rows
  themselves live behind `Tymeslot.Integrations.Calendar.ColourOverrideQueries`.
  """

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.ColourOverrideQueries
  alias Tymeslot.Integrations.Calendar.ColourResolver
  alias Tymeslot.Integrations.Calendar.ColourWriteBack
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Meetings

  @type user_id :: pos_integer()
  @type integration_id :: pos_integer()
  @type colour_target :: {:meeting, Ecto.UUID.t()} | {:external, integration_id(), String.t()}

  @doc """
  Sets a durable per-event colour override for `user_id` on `target`, then
  (for external events) best-effort writes it back to the provider. Returns the
  persisted override.
  """
  @spec set_event_colour(user_id(), colour_target(), String.t()) ::
          {:ok, term()} | {:error, :not_found | Ecto.Changeset.t()}
  def set_event_colour(user_id, target, colour) do
    with :ok <- verify_colour_target(user_id, target) do
      put_event_colour(user_id, target, colour)
    end
  end

  defp put_event_colour(user_id, {:meeting, meeting_id}, colour),
    do: ColourOverrideQueries.set_meeting(user_id, meeting_id, colour)

  defp put_event_colour(user_id, {:external, integration_id, uid}, colour) do
    with {:ok, override} <-
           ColourOverrideQueries.set_external(user_id, integration_id, uid, colour) do
      ColourWriteBack.enqueue(user_id, integration_id, uid, colour)
      {:ok, override}
    end
  end

  @doc """
  Clears a per-event colour override for `user_id` on `target`. For external
  events the host calendar's colour is cleared too, by the same write-back a
  set enqueues (`ColourWriteBack`, with a `nil` colour): its unique key
  replaces a write-back of the old colour still waiting, which would
  otherwise land after the clear and bring the colour back.

  Until that write-back has cleared the host, every sync reads the old
  colour back into the cache, so the override is not deleted but kept with
  a `nil` colour, which displays as no colour ahead of the cached one. The
  worker deletes it once the host is clear; a write-back that never
  succeeds leaves it in place, so the colour stays off in Tymeslot. An
  Outlook event keeps no colour of its own, so only its override goes.
  """
  @spec clear_event_colour(user_id(), colour_target()) :: :ok | {:error, :not_found}
  def clear_event_colour(user_id, target) do
    with :ok <- verify_colour_target(user_id, target) do
      remove_event_colour(user_id, target)
    end
  end

  defp remove_event_colour(user_id, {:meeting, meeting_id}),
    do: ColourOverrideQueries.clear_meeting(user_id, meeting_id)

  # An event whose provider keeps no colour of its own (Outlook) has none to
  # clear: its cached colour is the calendar's, which the next sync brings
  # back anyway.
  defp remove_event_colour(user_id, {:external, integration_id, uid}) do
    if host_colour?(integration_id, uid) do
      :ok = ColourOverrideQueries.mark_external_cleared(user_id, integration_id, uid)
      :ok = ProviderCalendarEventQueries.clear_colour(integration_id, uid)
      ColourWriteBack.enqueue(user_id, integration_id, uid, nil)
    else
      ColourOverrideQueries.clear_external(user_id, integration_id, uid)
    end
  end

  defp host_colour?(integration_id, uid) do
    case ProviderCalendarEventQueries.get_by_uid(integration_id, uid) do
      {:ok, event} -> ColourWriteBack.host_colour?(event.provider)
      {:error, :not_found} -> true
    end
  end

  # The target arrives from the browser, so the meeting or integration it
  # names must be the user's own; one that is not is not found.
  defp verify_colour_target(user_id, {:meeting, meeting_id}) do
    with {:ok, _meeting} <- Meetings.get_meeting_for_organizer(meeting_id, user_id), do: :ok
  end

  defp verify_colour_target(user_id, {:external, integration_id, _uid}) do
    if CalendarIntegrationQueries.owned_by?(integration_id, user_id),
      do: :ok,
      else: {:error, :not_found}
  end

  @doc """
  Returns a user's colour overrides as a lookup map keyed for the resolver:
  `{:meeting, id}` / `{:external, integration_id, uid}` => palette key, or
  `nil` for an external event whose colour was cleared.
  """
  @spec overrides_for(user_id()) :: %{optional(tuple()) => String.t() | nil}
  defdelegate overrides_for(user_id), to: ColourOverrideQueries, as: :for_user

  @doc """
  Resolves the palette key to display for the event `target`: the user's
  durable override in `overrides` wins (a cleared one meaning no colour),
  else the provider-synced colour, else `nil` (caller applies its own
  source/integration default).
  """
  @spec resolve_event_colour(map(), tuple(), provider_colour :: String.t() | nil) ::
          String.t() | nil
  defdelegate resolve_event_colour(overrides, target, provider_colour),
    to: ColourResolver,
    as: :resolve
end
