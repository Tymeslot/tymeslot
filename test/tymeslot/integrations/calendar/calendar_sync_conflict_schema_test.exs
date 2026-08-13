defmodule Tymeslot.Integrations.Calendar.CalendarSyncConflictSchemaTest do
  @moduledoc """
  The conflict audit row: the vocabulary it accepts for a divergence and its
  resolution, and the `occurred_at` default that keeps a caller from recording
  a conflict with no time on it at all.
  """
  use Tymeslot.DataCase, async: true

  @moduletag :calendar
  @moduletag :sync_links

  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.CalendarSyncConflictSchema

  setup do
    link = insert(:calendar_sync_link)
    {:ok, link: link}
  end

  defp attrs(link, overrides \\ %{}) do
    Map.merge(
      %{
        sync_link_id: link.id,
        source_uid: "source-uid-1",
        kind: "both_changed",
        resolution: "source_won"
      },
      overrides
    )
  end

  describe "changeset/2" do
    test "accepts a minimal record and defaults detail to an empty map", %{link: link} do
      assert {:ok, conflict} =
               %CalendarSyncConflictSchema{}
               |> CalendarSyncConflictSchema.changeset(attrs(link))
               |> Repo.insert()

      assert conflict.detail == %{}
    end

    test "stamps occurred_at when the caller does not supply one", %{link: link} do
      before = DateTime.utc_now()

      {:ok, conflict} =
        %CalendarSyncConflictSchema{}
        |> CalendarSyncConflictSchema.changeset(attrs(link))
        |> Repo.insert()

      assert DateTime.compare(conflict.occurred_at, before) in [:gt, :eq]
    end

    test "keeps an occurred_at the caller supplies, so a sweep can backdate", %{link: link} do
      earlier = DateTime.add(DateTime.utc_now(), -3600, :second)

      {:ok, conflict} =
        %CalendarSyncConflictSchema{}
        |> CalendarSyncConflictSchema.changeset(attrs(link, %{occurred_at: earlier}))
        |> Repo.insert()

      assert DateTime.compare(conflict.occurred_at, earlier) == :eq
    end

    test "stores the compared timestamps and etags in detail", %{link: link} do
      detail = %{"source_etag" => "abc", "target_etag" => "def"}

      {:ok, conflict} =
        %CalendarSyncConflictSchema{}
        |> CalendarSyncConflictSchema.changeset(attrs(link, %{detail: detail}))
        |> Repo.insert()

      assert conflict.detail == detail
    end

    test "requires the link, the source UID, the kind and the resolution", _ctx do
      changeset = CalendarSyncConflictSchema.changeset(%CalendarSyncConflictSchema{}, %{})

      errors = errors_on(changeset)
      assert "can't be blank" in errors.sync_link_id
      assert "can't be blank" in errors.source_uid
      assert "can't be blank" in errors.kind
      assert "can't be blank" in errors.resolution
    end

    for kind <- ~w(both_changed mirror_edited delete_race write_failed) do
      test "accepts the #{kind} kind", %{link: link} do
        changeset =
          CalendarSyncConflictSchema.changeset(
            %CalendarSyncConflictSchema{},
            attrs(link, %{kind: unquote(kind)})
          )

        assert changeset.valid?
      end
    end

    for resolution <- ~w(source_won deletion_won skipped) do
      test "accepts the #{resolution} resolution", %{link: link} do
        changeset =
          CalendarSyncConflictSchema.changeset(
            %CalendarSyncConflictSchema{},
            attrs(link, %{resolution: unquote(resolution)})
          )

        assert changeset.valid?
      end
    end

    test "rejects a kind the dashboard has no wording for", %{link: link} do
      changeset =
        CalendarSyncConflictSchema.changeset(
          %CalendarSyncConflictSchema{},
          attrs(link, %{kind: "something_else"})
        )

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).kind
    end

    test "rejects a resolution the engine never produces", %{link: link} do
      changeset =
        CalendarSyncConflictSchema.changeset(
          %CalendarSyncConflictSchema{},
          attrs(link, %{resolution: "coin_flip"})
        )

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).resolution
    end
  end

  describe "database constraints" do
    test "deleting the link cascades its conflict history away", %{link: link} do
      {:ok, conflict} =
        %CalendarSyncConflictSchema{}
        |> CalendarSyncConflictSchema.changeset(attrs(link))
        |> Repo.insert()

      Repo.delete!(link)

      refute Repo.get(CalendarSyncConflictSchema, conflict.id)
    end

    test "a foreign key to a missing link is reported on the field", %{link: link} do
      assert {:error, changeset} =
               %CalendarSyncConflictSchema{}
               |> CalendarSyncConflictSchema.changeset(attrs(link, %{sync_link_id: 0}))
               |> Repo.insert()

      assert "does not exist" in errors_on(changeset).sync_link_id
    end
  end
end
