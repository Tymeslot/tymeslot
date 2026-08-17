defmodule Tymeslot.Integrations.Calendar.SyncLink.MirrorColour do
  @moduledoc """
  Paints a placeholder the colour its link asks for, if the target has colours
  to paint with.

  Split out of `SyncLink.Engine` because it is the one part of a mirror write
  that is allowed to fail without the write failing. Everything else there is
  the operation; this is decoration applied after it, with its own rule about
  what a failure means, and keeping the two in one module made that rule easy
  to read as an oversight rather than a decision.

  ## Why it is a second call rather than a field on the payload

  `patch_event_colour/4` lives on `Google.GoogleCalendarApi`. It is not part of
  the shared `Provider` behaviour and cannot be dispatched polymorphically, so
  there is no colour field to put on a payload three provider families share.
  Every other target declines on a function head and no request is made at all.

  The CalDAV family does have a `COLOR` property, and it is still declined: the
  colour-only route patches the event's *cached* `raw_ical`, and a placeholder
  Tymeslot has only just written is not in the target's cache yet, so there
  would be nothing to patch.

  ## Why a failure is swallowed

  Once the placeholder is on the target it blocks the time it exists to block,
  which is the whole feature; the colour is decoration on top. A failure
  propagated here would return an error from the engine, Oban would retry the
  whole mirror, and the retry would re-send the placeholder — provider quota
  and a redundant write — to correct a hue.

  So the patch logs its own failure and returns the write's result untouched.
  That log is the only signal this path emits, which makes recognising success
  the whole of its correctness: `wrote?/1` from `ProviderEventId` decides, not a
  match written out here. Google is the sole provider that reaches the patch,
  and its answer is `{:ok, event}` — `patch_event_colour/4` returns the body and
  `OAuthBase.handle_write_api_call/2` converts it — so a match on the bare `:ok`
  recognised only the short-circuit for a colour Google has no id for, and
  reported every patch that actually landed as a failure.

  The next mirror write for that source repaints, because the patch is
  unconditional rather than diffed against a stored colour: no column records
  what colour the placeholder currently carries, and adding one to save a
  single PATCH would be bookkeeping that can itself drift.

  It runs only after a *successful* write. A failed create has no event to
  paint, and a failed update leaves a placeholder already being retried.
  """

  require Logger

  alias Tymeslot.Integrations.Calendar.CalendarSyncLinkSchema
  alias Tymeslot.Integrations.Calendar.Events, as: CalendarEvents
  alias Tymeslot.Integrations.Calendar.SyncLink.Capability

  import Tymeslot.Integrations.Calendar.SyncLink.ProviderEventId, only: [wrote?: 1]

  @doc """
  Whether this link's placeholders can be painted, and with what.

  `{:ok, colour}` only when the link carries a colour *and* its target is a
  provider with a per-event colour to set. Everything else is a discard naming
  the reason, in the same vocabulary the rest of the sync path uses — a colour
  that can never be applied is not a failure to retry.

  Which providers those are is `SyncLink.Capability`'s `:per_event_colour` to
  answer, not this module's.
  """
  @spec target(CalendarSyncLinkSchema.t()) :: {:ok, String.t()} | {:discard, atom()}
  def target(%CalendarSyncLinkSchema{mirror_colour: colour})
      when not is_binary(colour) or colour == "",
      do: {:discard, :no_mirror_colour}

  # A link whose target association was never loaded cannot be asked what
  # provider it points at. Named separately from the unsupported-provider case
  # because the two are different bugs: this one is a caller that skipped the
  # preload, and reporting it as "this provider has no colour" would send
  # whoever investigates to the wrong place. Both decline to paint, which is the
  # safe failure — the block is already on the target doing its job.
  def target(%CalendarSyncLinkSchema{target_integration: %Ecto.Association.NotLoaded{}}),
    do: {:discard, :target_integration_not_loaded}

  def target(%CalendarSyncLinkSchema{
        mirror_colour: colour,
        target_integration: %{provider: provider}
      }) do
    if Capability.supports?(provider, :per_event_colour) do
      {:ok, colour}
    else
      {:discard, :provider_has_no_event_colour}
    end
  end

  def target(%CalendarSyncLinkSchema{}), do: {:discard, :provider_has_no_event_colour}

  @doc """
  Paints the placeholder, and answers `result` whatever happens.

  `result` is the outcome of the write this follows, passed through untouched:
  a write that failed has nothing to paint, and a patch that fails must not turn
  a successful write into a failure. `calendar_opts` says which calendar the
  placeholder lives on — without it the PATCH addresses the target's primary
  calendar and 404s on every mirror of a link with a secondary target, silently,
  because a patch failure is swallowed by design.
  """
  @spec apply(
          term(),
          CalendarSyncLinkSchema.t(),
          String.t(),
          String.t() | nil,
          integer(),
          keyword()
        ) ::
          term()
  def apply(result, link, target_uid, provider_event_id, user_id, calendar_opts \\ [])

  def apply(:ok, link, target_uid, provider_event_id, user_id, calendar_opts) do
    case target(link) do
      {:ok, colour} ->
        patch(link, target_uid, provider_event_id, colour, user_id, calendar_opts)

      {:discard, _reason} ->
        :ok
    end

    :ok
  end

  def apply(result, _link, _target_uid, _provider_event_id, _user_id, _calendar_opts), do: result

  defp patch(link, target_uid, provider_event_id, colour, user_id, calendar_opts) do
    event_data =
      Enum.into(calendar_opts, %{
        colour_only: true,
        colour: colour,
        provider_event_id: provider_event_id
      })

    case CalendarEvents.update_event(
           target_uid,
           event_data,
           {link.target_integration_id, user_id}
         ) do
      landed when wrote?(landed) ->
        :ok

      other ->
        Logger.warning("Mirror colour patch failed; the placeholder keeps the target's default",
          sync_link_id: link.id,
          target_integration_id: link.target_integration_id,
          target_uid: target_uid,
          reason: inspect(other)
        )

        :ok
    end
  end
end
