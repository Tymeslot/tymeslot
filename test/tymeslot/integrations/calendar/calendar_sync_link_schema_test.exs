defmodule Tymeslot.Integrations.Calendar.CalendarSyncLinkSchemaTest do
  @moduledoc """
  The sync-link changeset: the validations that stop a link being created in a
  shape the engine cannot honour — a self-link, a read-only target, a privacy
  tier nothing implements, a colour outside the palette.
  """
  use Tymeslot.DataCase, async: true

  @moduletag :calendar
  @moduletag :sync_links

  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.Integrations.Calendar.CalendarSyncLinkSchema

  setup do
    user = insert(:user)
    source = insert(:calendar_integration, user: user, provider: "google")
    target = insert(:calendar_integration, user: user, provider: "google")

    {:ok, user: user, source: source, target: target}
  end

  defp attrs(ctx, overrides \\ %{}) do
    Map.merge(
      %{
        user_id: ctx.user.id,
        source_integration_id: ctx.source.id,
        target_integration_id: ctx.target.id,
        target_provider: "google"
      },
      overrides
    )
  end

  describe "changeset/2 required fields" do
    test "accepts the minimal valid link", ctx do
      changeset = CalendarSyncLinkSchema.changeset(%CalendarSyncLinkSchema{}, attrs(ctx))

      assert changeset.valid?
    end

    test "requires the owner and both integrations", _ctx do
      changeset = CalendarSyncLinkSchema.changeset(%CalendarSyncLinkSchema{}, %{})

      errors = errors_on(changeset)
      assert "can't be blank" in errors.user_id
      assert "can't be blank" in errors.source_integration_id
      assert "can't be blank" in errors.target_integration_id
    end
  end

  describe "changeset/2 no self-link" do
    test "rejects a link whose source and target are the same integration", ctx do
      changeset =
        CalendarSyncLinkSchema.changeset(
          %CalendarSyncLinkSchema{},
          attrs(ctx, %{target_integration_id: ctx.source.id})
        )

      refute changeset.valid?
      assert "cannot mirror a calendar onto itself" in errors_on(changeset).target_integration_id
    end
  end

  describe "changeset/2 target capability" do
    test "rejects a subscription provider as the target", ctx do
      changeset =
        CalendarSyncLinkSchema.changeset(
          %CalendarSyncLinkSchema{},
          attrs(ctx, %{target_provider: "ics_url"})
        )

      refute changeset.valid?

      assert "is a read-only subscription and cannot receive mirrored events" in errors_on(
               changeset
             ).target_integration_id
    end

    test "accepts a subscription provider as the source", ctx do
      ics = insert(:calendar_integration, user: ctx.user, provider: "ics_url")

      changeset =
        CalendarSyncLinkSchema.changeset(
          %CalendarSyncLinkSchema{},
          attrs(ctx, %{source_integration_id: ics.id})
        )

      assert changeset.valid?
    end

    test "forces target_calendar_id to nil for a CalDAV-family target", ctx do
      changeset =
        CalendarSyncLinkSchema.changeset(
          %CalendarSyncLinkSchema{},
          attrs(ctx, %{target_provider: "nextcloud", target_calendar_id: "work"})
        )

      assert changeset.valid?
      assert Changeset.get_field(changeset, :target_calendar_id) == nil
    end

    test "keeps target_calendar_id for a provider that honours it", ctx do
      changeset =
        CalendarSyncLinkSchema.changeset(
          %CalendarSyncLinkSchema{},
          attrs(ctx, %{target_provider: "google", target_calendar_id: "work"})
        )

      assert changeset.valid?
      assert Changeset.get_field(changeset, :target_calendar_id) == "work"
    end

    test "leaves the target unchecked when no target_provider is supplied", ctx do
      changeset =
        CalendarSyncLinkSchema.changeset(
          %CalendarSyncLinkSchema{},
          Map.delete(attrs(ctx), :target_provider)
        )

      assert changeset.valid?
    end

    test "does not persist target_provider as a column", ctx do
      assert {:ok, link} =
               %CalendarSyncLinkSchema{}
               |> CalendarSyncLinkSchema.changeset(attrs(ctx))
               |> Repo.insert()

      assert Repo.reload(link)
    end
  end

  describe "changeset/2 privacy_tier" do
    test "defaults to busy_only", ctx do
      assert {:ok, link} =
               %CalendarSyncLinkSchema{}
               |> CalendarSyncLinkSchema.changeset(attrs(ctx))
               |> Repo.insert()

      assert link.privacy_tier == "busy_only"
    end

    # `generic_label` carries its label, because that tier is the one whose
    # rendering depends on a second field; see the `generic_label` describe
    # block below for the rule.
    for {tier, extra} <- [
          {"busy_only", %{}},
          {"generic_label", %{generic_label: "Personal commitment"}},
          {"full_passthrough", %{}}
        ] do
      test "accepts #{tier}", ctx do
        changeset =
          CalendarSyncLinkSchema.changeset(
            %CalendarSyncLinkSchema{},
            attrs(ctx, Map.merge(%{privacy_tier: unquote(tier)}, unquote(Macro.escape(extra))))
          )

        assert changeset.valid?
      end
    end

    test "rejects a tier nothing implements", ctx do
      changeset =
        CalendarSyncLinkSchema.changeset(
          %CalendarSyncLinkSchema{},
          attrs(ctx, %{privacy_tier: "everything"})
        )

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).privacy_tier
    end
  end

  describe "changeset/2 generic_label" do
    # The tier promises a placeholder titled in the organiser's own words, and
    # `MirrorPayload` degrades a blank label to the plain "Busy" title. A link
    # accepted without one would therefore be described everywhere as showing a
    # generic label while every placeholder it wrote read "Busy".
    test "is required at the tier that renders it", ctx do
      changeset =
        CalendarSyncLinkSchema.changeset(
          %CalendarSyncLinkSchema{},
          attrs(ctx, %{privacy_tier: "generic_label"})
        )

      refute changeset.valid?
      assert errors_on(changeset).generic_label != []
    end

    # Whitespace passes `validate_required/2` untouched and then renders as
    # "Busy" — the same broken promise by a longer route — so blankness is
    # measured the way `MirrorPayload` measures it.
    test "treats a whitespace-only label as missing", ctx do
      changeset =
        CalendarSyncLinkSchema.changeset(
          %CalendarSyncLinkSchema{},
          attrs(ctx, %{privacy_tier: "generic_label", generic_label: "   "})
        )

      refute changeset.valid?
      assert errors_on(changeset).generic_label != []
    end

    test "stores the label trimmed, so the row and the placeholder agree", ctx do
      changeset =
        CalendarSyncLinkSchema.changeset(
          %CalendarSyncLinkSchema{},
          attrs(ctx, %{privacy_tier: "generic_label", generic_label: "  Away  "})
        )

      assert changeset.valid?
      assert Changeset.get_change(changeset, :generic_label) == "Away"
    end

    # The other two tiers never read the field, so requiring it there would
    # block a link over a value that could not appear on any placeholder.
    test "is not required at the tiers that ignore it", ctx do
      for tier <- ~w(busy_only full_passthrough) do
        changeset =
          CalendarSyncLinkSchema.changeset(
            %CalendarSyncLinkSchema{},
            attrs(ctx, %{privacy_tier: tier})
          )

        assert changeset.valid?, "#{tier} should not require a generic label"
      end
    end
  end

  describe "changeset/2 mirror_colour" do
    test "accepts nil, meaning inherit the target integration's colour", ctx do
      changeset =
        CalendarSyncLinkSchema.changeset(
          %CalendarSyncLinkSchema{},
          attrs(ctx, %{mirror_colour: nil})
        )

      assert changeset.valid?
    end

    test "accepts a palette key", ctx do
      changeset =
        CalendarSyncLinkSchema.changeset(
          %CalendarSyncLinkSchema{},
          attrs(ctx, %{mirror_colour: "sage"})
        )

      assert changeset.valid?
    end

    test "rejects a colour outside the palette", ctx do
      changeset =
        CalendarSyncLinkSchema.changeset(
          %CalendarSyncLinkSchema{},
          attrs(ctx, %{mirror_colour: "chartreuse"})
        )

      refute changeset.valid?
      assert "is not a palette colour" in errors_on(changeset).mirror_colour
    end
  end

  describe "field lengths" do
    # All three are `varchar(255)`. Without a changeset rule the overflow
    # reaches Postgres as a 22001 and raises out of the LiveView that submitted
    # it — the organiser sees "Connection Lost" rather than a form error. And
    # `generic_label` is free text with a prose placeholder, so a pasted
    # sentence gets there without anyone trying.
    test "a generic label longer than the column is refused, not raised", ctx do
      changeset =
        CalendarSyncLinkSchema.changeset(
          %CalendarSyncLinkSchema{},
          attrs(ctx, %{privacy_tier: "generic_label", generic_label: String.duplicate("a", 256)})
        )

      refute changeset.valid?
      assert %{generic_label: [_message]} = errors_on(changeset)
    end

    test "a target calendar id longer than the column is refused", ctx do
      changeset =
        CalendarSyncLinkSchema.changeset(
          %CalendarSyncLinkSchema{},
          attrs(ctx, %{target_calendar_id: String.duplicate("c", 256)})
        )

      refute changeset.valid?
      assert %{target_calendar_id: [_message]} = errors_on(changeset)
    end

    test "a label exactly at the limit is accepted", ctx do
      changeset =
        CalendarSyncLinkSchema.changeset(
          %CalendarSyncLinkSchema{},
          attrs(ctx, %{privacy_tier: "generic_label", generic_label: String.duplicate("a", 255)})
        )

      assert changeset.valid?
    end
  end

  describe "database constraints" do
    test "the unique index rejects a duplicate source/target/calendar triple", ctx do
      insert_attrs = attrs(ctx, %{target_calendar_id: "work"})

      assert {:ok, _link} =
               %CalendarSyncLinkSchema{}
               |> CalendarSyncLinkSchema.changeset(insert_attrs)
               |> Repo.insert()

      assert {:error, changeset} =
               %CalendarSyncLinkSchema{}
               |> CalendarSyncLinkSchema.changeset(insert_attrs)
               |> Repo.insert()

      assert "has already been linked" in errors_on(changeset).source_integration_id
    end

    # The index carries `nulls_distinct: false` for this case alone. Postgres
    # treats NULLs as distinct by default, and every CalDAV-family target has
    # target_calendar_id forced nil, so under the default the seven CalDAV
    # providers would have no uniqueness guarantee at all — and a duplicate
    # link mirrors every source event onto the same calendar twice.
    test "the unique index rejects a duplicate when the target calendar is nil", ctx do
      insert_attrs = attrs(ctx, %{target_provider: "nextcloud", target_calendar_id: nil})

      assert {:ok, link} =
               %CalendarSyncLinkSchema{}
               |> CalendarSyncLinkSchema.changeset(insert_attrs)
               |> Repo.insert()

      assert is_nil(link.target_calendar_id)

      assert {:error, changeset} =
               %CalendarSyncLinkSchema{}
               |> CalendarSyncLinkSchema.changeset(insert_attrs)
               |> Repo.insert()

      assert "has already been linked" in errors_on(changeset).source_integration_id
    end

    test "the check constraint rejects a self-link that bypasses the changeset", ctx do
      # The changeset catches this, so reach past it: the constraint exists
      # precisely because a future direct insert would not go through it.
      changeset =
        %CalendarSyncLinkSchema{}
        |> CalendarSyncLinkSchema.changeset(attrs(ctx))
        |> Changeset.put_change(:target_integration_id, ctx.source.id)

      assert {:error, errored} = Repo.insert(changeset)

      assert "cannot mirror a calendar onto itself" in errors_on(errored).target_integration_id
    end

    test "deleting the source integration cascades the link away", ctx do
      {:ok, link} =
        %CalendarSyncLinkSchema{}
        |> CalendarSyncLinkSchema.changeset(attrs(ctx))
        |> Repo.insert()

      Repo.delete!(ctx.source)

      refute Repo.get(CalendarSyncLinkSchema, link.id)
    end

    test "deleting the target integration cascades the link away", ctx do
      {:ok, link} =
        %CalendarSyncLinkSchema{}
        |> CalendarSyncLinkSchema.changeset(attrs(ctx))
        |> Repo.insert()

      Repo.delete!(ctx.target)

      refute Repo.get(CalendarSyncLinkSchema, link.id)
    end

    test "a foreign key to a missing integration is reported on the field", ctx do
      assert {:error, changeset} =
               %CalendarSyncLinkSchema{}
               |> CalendarSyncLinkSchema.changeset(attrs(ctx, %{target_integration_id: 0}))
               |> Repo.insert()

      assert "does not exist" in errors_on(changeset).target_integration_id
    end
  end
end
