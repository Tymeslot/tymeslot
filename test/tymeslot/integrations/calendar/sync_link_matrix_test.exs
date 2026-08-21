defmodule Tymeslot.Integrations.Calendar.SyncLinkMatrixTest do
  @moduledoc """
  `apply_matrix/2`, the bulk write behind the link grid.

  The grid presents every ordered pair of calendars at once, so a save is a
  *diff* rather than a create. A cell carries three states, not two: `:active`
  mirrors, `:paused` keeps the link and its settings while writing nothing, and
  absence deletes. Cells that did not move are left strictly alone.

  That last rule is the one worth testing hardest — a save that recreated
  unchanged links would tear down their placeholders through `delete_link/2`
  and rewrite them, turning a no-op save into a burst of provider writes.

  The `:paused` state is why the grid stopped meaning "this link exists". An
  unticked cell used to delete, which withdrew every placeholder the link had
  written — irreversibly, and from a misclick. Pausing is the reversible half
  of that, and deletion moved to a deliberate action on the link's own card.

  Ownership is not re-implemented here: every write funnels through
  `create_link/2` and `delete_link/2`, which already verify it. The tests
  below check that the funnel is actually used rather than bypassed.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :calendar
  @moduletag :sync_links

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.SyncLink

  setup :verify_on_exit!
  setup :set_mox_from_context

  setup do
    user = insert(:user)

    calendars =
      for name <- ~w(Work Personal Team) do
        insert(:calendar_integration,
          user: user,
          provider: "google",
          name: name,
          is_active: true
        )
      end

    {:ok, user: user, calendars: calendars}
  end

  defp ids(links), do: MapSet.new(links, &{&1.source_integration_id, &1.target_integration_id})

  defp current_pairs(user_id) do
    user_id |> SyncLink.list_links() |> ids()
  end

  describe "apply_matrix/2" do
    test "creates a link for every newly ticked cell", ctx do
      %{user: user, calendars: [work, personal, _team]} = ctx

      assert {:ok, summary} =
               SyncLink.apply_matrix(user.id, %{
                 {work.id, personal.id} => :active,
                 {personal.id, work.id} => :active
               })

      assert summary.created == 2
      assert summary.deleted == 0

      assert current_pairs(user.id) ==
               MapSet.new([{work.id, personal.id}, {personal.id, work.id}])
    end

    test "deletes a link for every cell cleared", ctx do
      %{user: user, calendars: [work, personal, _team]} = ctx

      {:ok, _summary} = SyncLink.apply_matrix(user.id, %{{work.id, personal.id} => :active})

      assert {:ok, summary} = SyncLink.apply_matrix(user.id, %{})

      assert summary.deleted == 1
      assert current_pairs(user.id) == MapSet.new()
    end

    test "leaves an unchanged cell's link row untouched", ctx do
      # The load-bearing case: re-saving a grid nobody edited must not churn.
      # Recreating a link deletes it first, and `delete_link/2` tears the
      # placeholders off the provider on its way out — so a no-op save that
      # recreated rows would withdraw and rewrite every mirror in the set.
      %{user: user, calendars: [work, personal, _team]} = ctx

      {:ok, _summary} = SyncLink.apply_matrix(user.id, %{{work.id, personal.id} => :active})
      [before] = SyncLink.list_links(user.id)

      assert {:ok, summary} = SyncLink.apply_matrix(user.id, %{{work.id, personal.id} => :active})

      assert summary.created == 0
      assert summary.deleted == 0

      [unchanged] = SyncLink.list_links(user.id)
      assert unchanged.id == before.id
      assert unchanged.inserted_at == before.inserted_at
    end

    test "applies creations and deletions in one save", ctx do
      %{user: user, calendars: [work, personal, team]} = ctx

      {:ok, _summary} = SyncLink.apply_matrix(user.id, %{{work.id, personal.id} => :active})

      assert {:ok, summary} =
               SyncLink.apply_matrix(user.id, %{
                 {work.id, personal.id} => :active,
                 {work.id, team.id} => :active
               })

      assert summary.created == 1
      assert summary.deleted == 0

      assert current_pairs(user.id) ==
               MapSet.new([{work.id, personal.id}, {work.id, team.id}])
    end

    test "refuses a cell naming a calendar the user does not own", ctx do
      %{user: user, calendars: [work, _personal, _team]} = ctx
      stranger = insert(:calendar_integration, provider: "google", is_active: true)

      assert {:error, :not_found} =
               SyncLink.apply_matrix(user.id, %{{work.id, stranger.id} => :active})

      # Nothing partially applied: the rejected pair leaves no rows behind.
      assert current_pairs(user.id) == MapSet.new()
    end

    test "refuses the whole save when one cell is invalid", ctx do
      # A grid save is one deliberate action. Applying the valid half and
      # reporting an error would leave the organiser looking at a grid that no
      # longer matches what was stored.
      %{user: user, calendars: [work, personal, _team]} = ctx
      stranger = insert(:calendar_integration, provider: "google", is_active: true)

      assert {:error, :not_found} =
               SyncLink.apply_matrix(user.id, %{
                 {work.id, personal.id} => :active,
                 {work.id, stranger.id} => :active
               })

      assert current_pairs(user.id) == MapSet.new()
    end

    test "refuses a self-link cell", ctx do
      %{user: user, calendars: [work, _personal, _team]} = ctx

      assert {:error, _reason} = SyncLink.apply_matrix(user.id, %{{work.id, work.id} => :active})

      assert current_pairs(user.id) == MapSet.new()
    end

    test "leaves links belonging to another user alone", ctx do
      %{user: user, calendars: [work, personal, _team]} = ctx

      other = insert(:user)

      other_source =
        insert(:calendar_integration, user: other, provider: "google", is_active: true)

      other_target =
        insert(:calendar_integration, user: other, provider: "google", is_active: true)

      {:ok, _summary} =
        SyncLink.apply_matrix(other.id, %{{other_source.id, other_target.id} => :active})

      # Clearing this user's grid must not reach across into another's rows.
      {:ok, _summary} = SyncLink.apply_matrix(user.id, %{{work.id, personal.id} => :active})
      {:ok, summary} = SyncLink.apply_matrix(user.id, %{})

      assert summary.deleted == 1
      assert current_pairs(other.id) == MapSet.new([{other_source.id, other_target.id}])
    end

    test "resuming a paused cell keeps the same row rather than recreating it", ctx do
      # A resume must not go through create: the link's settings — its privacy
      # tier, its label, its target calendar — live on the row, and a recreate
      # would silently reset every one of them to the defaults.
      %{user: user, calendars: [work, personal, _team]} = ctx

      {:ok, _summary} = SyncLink.apply_matrix(user.id, %{{work.id, personal.id} => :paused})
      [paused] = SyncLink.list_links(user.id)
      refute paused.enabled

      {:ok, _updated} =
        SyncLink.update_link(user.id, paused.id, %{
          "privacy_tier" => "generic_label",
          "generic_label" => "Elsewhere"
        })

      assert {:ok, summary} = SyncLink.apply_matrix(user.id, %{{work.id, personal.id} => :active})
      assert summary.created == 0
      assert summary.deleted == 0

      [resumed] = SyncLink.list_links(user.id)
      assert resumed.id == paused.id
      assert resumed.enabled
      assert resumed.generic_label == "Elsewhere"
    end

    test "pausing an active cell keeps the link and writes nothing to the provider", ctx do
      # The reason the grid stopped deleting. Pausing is the reversible answer
      # to "stop mirroring this", and it must not reach `delete_link/2`, which
      # withdraws every placeholder the link has written. No provider
      # expectation is declared, so a call to one fails this test.
      %{user: user, calendars: [work, personal, _team]} = ctx

      {:ok, _summary} = SyncLink.apply_matrix(user.id, %{{work.id, personal.id} => :active})
      [active] = SyncLink.list_links(user.id)

      assert {:ok, summary} = SyncLink.apply_matrix(user.id, %{{work.id, personal.id} => :paused})
      assert summary.created == 0
      assert summary.deleted == 0

      [paused] = SyncLink.list_links(user.id)
      assert paused.id == active.id
      refute paused.enabled
    end

    test "creates a cell that arrives already paused", ctx do
      # The grid can stage a create and a pause together — tick a cell, then
      # click it once more before saving. The link is configured but dormant.
      %{user: user, calendars: [work, personal, _team]} = ctx

      assert {:ok, summary} =
               SyncLink.apply_matrix(user.id, %{{work.id, personal.id} => :paused})

      assert summary.created == 1

      [link] = SyncLink.list_links(user.id)
      refute link.enabled
    end

    test "leaves a paused cell alone when the save does not move it", ctx do
      # The no-churn rule, on the paused half of the diff.
      %{user: user, calendars: [work, personal, _team]} = ctx

      {:ok, _summary} = SyncLink.apply_matrix(user.id, %{{work.id, personal.id} => :paused})
      [before] = SyncLink.list_links(user.id)

      assert {:ok, summary} = SyncLink.apply_matrix(user.id, %{{work.id, personal.id} => :paused})
      assert summary.created == 0
      assert summary.deleted == 0

      [unchanged] = SyncLink.list_links(user.id)
      assert unchanged.id == before.id
      assert unchanged.updated_at == before.updated_at
    end
  end
end
