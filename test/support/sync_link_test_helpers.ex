defmodule Tymeslot.SyncLinkTestHelpers do
  @moduledoc """
  Setup shared by the cross-calendar mirroring tests.

  Every one of them needs the same three rows before it can say anything: an
  organiser, two calendars they own, and a link pointing one at the other. A
  link across two users is a shape the context refuses, so building the trio by
  hand in each file is both repetitive and easy to get subtly wrong — and
  getting it wrong produces a link that cannot exist in production, which is a
  worse failure than a duplicated block.
  """

  import Tymeslot.Factory

  @doc """
  An organiser with a source calendar, a target calendar, and an enabled link
  from the first to the second.

  Both integrations are Google, the provider that honours `:calendar_id` on
  write and assigns event ids server-side — the combination the engine's
  interesting paths (targeted writes, orphan compensation) are shaped by.
  """
  @spec linked_pair() :: %{
          user: Tymeslot.Auth.UserSchema.t(),
          source: Tymeslot.Integrations.Calendar.CalendarIntegrationSchema.t(),
          target: Tymeslot.Integrations.Calendar.CalendarIntegrationSchema.t(),
          link: Tymeslot.Integrations.Calendar.CalendarSyncLinkSchema.t()
        }
  def linked_pair do
    user = insert(:user)
    source = insert(:calendar_integration, user: user, provider: "google")
    target = insert(:calendar_integration, user: user, provider: "google")

    link =
      insert(:calendar_sync_link,
        user_id: user.id,
        source_integration_id: source.id,
        target_integration_id: target.id
      )

    %{user: user, source: source, target: target, link: link}
  end

  @doc """
  A second link out of the same source, onto a freshly created third calendar.

  The fan-out case: one source event on two links is two placeholders.
  """
  @spec extra_target_link(map()) ::
          {Tymeslot.Integrations.Calendar.CalendarIntegrationSchema.t(),
           Tymeslot.Integrations.Calendar.CalendarSyncLinkSchema.t()}
  def extra_target_link(%{user: user, source: source}) do
    target = insert(:calendar_integration, user: user, provider: "google")

    link =
      insert(:calendar_sync_link,
        user_id: user.id,
        source_integration_id: source.id,
        target_integration_id: target.id
      )

    {target, link}
  end

  @doc """
  The link pointing the other way, making the pair bidirectional.

  This is the configuration loop prevention exists for: without it, a
  placeholder written onto the target comes back on the target's own inbound
  sync as an ordinary event and is mirrored straight back.
  """
  @spec reverse_link(map()) :: Tymeslot.Integrations.Calendar.CalendarSyncLinkSchema.t()
  def reverse_link(%{user: user, source: source, target: target}) do
    insert(:calendar_sync_link,
      user_id: user.id,
      source_integration_id: target.id,
      target_integration_id: source.id
    )
  end
end
