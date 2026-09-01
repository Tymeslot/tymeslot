defmodule Tymeslot.MeetingTypes.MeetingTypeSchemaTest do
  use Tymeslot.DataCase, async: true

  @moduletag :meeting_types
  @moduletag :database
  @moduletag :schema

  alias Ecto.Changeset
  alias Tymeslot.MeetingTypes.MeetingTypeSchema

  describe "changeset/2 with custom_fields" do
    test "defaults to empty list" do
      cs =
        MeetingTypeSchema.changeset(%MeetingTypeSchema{}, %{
          "name" => "30 min chat",
          "duration_minutes" => 30,
          "user_id" => 1
        })

      assert Changeset.get_field(cs, :custom_fields) == []
    end

    test "accepts an array of field definitions" do
      attrs = %{
        "name" => "30 min chat",
        "duration_minutes" => 30,
        "user_id" => 1,
        "custom_fields" => [
          %{"type" => "short_text", "label" => "Company"},
          %{"type" => "yes_no", "label" => "Bringing laptop?"}
        ]
      }

      cs = MeetingTypeSchema.changeset(%MeetingTypeSchema{}, attrs)
      assert cs.valid?
      assert length(Changeset.get_field(cs, :custom_fields)) == 2
    end

    test "invalid field definitions surface errors" do
      attrs = %{
        "name" => "x",
        "duration_minutes" => 30,
        "user_id" => 1,
        "custom_fields" => [%{"type" => "rich_text", "label" => "Bad"}]
      }

      cs = MeetingTypeSchema.changeset(%MeetingTypeSchema{}, attrs)
      refute cs.valid?

      # Error must originate from the embedded changeset, not the parent.
      [embed_cs] = Changeset.get_change(cs, :custom_fields)
      refute embed_cs.valid?
      assert "is invalid" in errors_on(embed_cs).type
    end
  end

  describe "business rules" do
    test "prevents meetings longer than 8 hours" do
      user = insert(:user)

      attrs = %{
        name: "All Day Meeting",
        duration_minutes: 481,
        user_id: user.id
      }

      changeset = MeetingTypeSchema.changeset(%MeetingTypeSchema{}, attrs)
      refute changeset.valid?
      assert "must be less than or equal to 480" in errors_on(changeset).duration_minutes
    end

    test "prevents zero-duration meetings" do
      user = insert(:user)

      attrs = %{
        name: "No Time Meeting",
        duration_minutes: 0,
        user_id: user.id
      }

      changeset = MeetingTypeSchema.changeset(%MeetingTypeSchema{}, attrs)
      refute changeset.valid?
      assert "must be greater than or equal to 1" in errors_on(changeset).duration_minutes
    end

    test "prevents duplicate meeting type names per user" do
      user = insert(:user)
      insert(:meeting_type, user: user, name: "Daily Standup", allow_video: false)

      {:error, changeset} =
        %MeetingTypeSchema{}
        |> MeetingTypeSchema.changeset(%{
          name: "Daily Standup",
          duration_minutes: 30,
          user_id: user.id,
          allow_video: false
        })
        |> Repo.insert()

      assert "You already have a meeting type with this name" in errors_on(changeset).user_id
    end

    test "schema allows non-divisible-by-5 durations (form layer enforces this)" do
      user = insert(:user)

      attrs = %{
        name: "Odd Duration",
        duration_minutes: 7,
        user_id: user.id
      }

      changeset = MeetingTypeSchema.changeset(%MeetingTypeSchema{}, attrs)
      assert changeset.valid?
    end

    test "prevents more than three reminders" do
      user = insert(:user)

      attrs = %{
        name: "Reminder Packed",
        duration_minutes: 30,
        user_id: user.id,
        reminder_config: [
          %{value: 15, unit: "minutes"},
          %{value: 30, unit: "minutes"},
          %{value: 1, unit: "hours"},
          %{value: 1, unit: "days"}
        ]
      }

      changeset = MeetingTypeSchema.changeset(%MeetingTypeSchema{}, attrs)
      refute changeset.valid?
      assert "cannot have more than 3 reminders" in errors_on(changeset).reminder_config
    end
  end

  describe "payment_required validation" do
    test "free meeting type does not require price" do
      user = insert(:user)

      attrs = %{
        name: "Free Chat",
        duration_minutes: 30,
        payment_required: false,
        user_id: user.id
      }

      changeset = MeetingTypeSchema.changeset(%MeetingTypeSchema{}, attrs)
      refute Map.has_key?(errors_on(changeset), :price_cents)
    end

    test "paid meeting type requires price_cents" do
      user = insert(:user)

      attrs = %{
        name: "Paid",
        duration_minutes: 30,
        payment_required: true,
        user_id: user.id
      }

      changeset =
        MeetingTypeSchema.changeset(%MeetingTypeSchema{}, attrs,
          currency: "eur",
          host_charges_enabled: true
        )

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).price_cents
    end

    test "rejects price below currency minimum" do
      user = insert(:user)

      attrs = %{
        name: "Paid",
        duration_minutes: 30,
        payment_required: true,
        price_cents: 25,
        user_id: user.id
      }

      changeset =
        MeetingTypeSchema.changeset(%MeetingTypeSchema{}, attrs,
          currency: "eur",
          host_charges_enabled: true
        )

      refute changeset.valid?
      assert "must be at least EUR 0.50" in errors_on(changeset).price_cents
    end

    test "accepts price at or above currency minimum" do
      user = insert(:user)

      attrs = %{
        name: "Paid",
        duration_minutes: 30,
        payment_required: true,
        price_cents: 5000,
        user_id: user.id
      }

      changeset =
        MeetingTypeSchema.changeset(%MeetingTypeSchema{}, attrs,
          currency: "eur",
          host_charges_enabled: true
        )

      refute Map.has_key?(errors_on(changeset), :price_cents)
      refute Map.has_key?(errors_on(changeset), :payment_required)
    end

    test "rejects payment_required without connected Stripe" do
      user = insert(:user)

      attrs = %{
        name: "Paid",
        duration_minutes: 30,
        payment_required: true,
        price_cents: 5000,
        user_id: user.id
      }

      changeset =
        MeetingTypeSchema.changeset(%MeetingTypeSchema{}, attrs,
          currency: "eur",
          host_charges_enabled: false
        )

      refute changeset.valid?
      assert "Stripe must be connected" in errors_on(changeset).payment_required
    end

    test "reports both errors when price is missing and Stripe is not connected" do
      user = insert(:user)

      attrs = %{
        name: "Paid",
        duration_minutes: 30,
        payment_required: true,
        user_id: user.id
      }

      changeset =
        MeetingTypeSchema.changeset(%MeetingTypeSchema{}, attrs,
          currency: "eur",
          host_charges_enabled: false
        )

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).price_cents
      assert "Stripe must be connected" in errors_on(changeset).payment_required
    end

    test "defaults currency to usd when opt is omitted" do
      user = insert(:user)

      attrs = %{
        name: "Paid",
        duration_minutes: 30,
        payment_required: true,
        price_cents: 25,
        user_id: user.id
      }

      changeset =
        MeetingTypeSchema.changeset(%MeetingTypeSchema{}, attrs, host_charges_enabled: true)

      refute changeset.valid?
      assert "must be at least USD 0.50" in errors_on(changeset).price_cents
    end
  end

  describe "slot_interval_minutes" do
    test "defaults to nil so an existing type keeps using its event length" do
      changeset = MeetingTypeSchema.changeset(%MeetingTypeSchema{}, valid_attrs())

      assert Changeset.get_field(changeset, :slot_interval_minutes) == nil
    end

    test "accepts an interval shorter than the duration" do
      changeset =
        MeetingTypeSchema.changeset(
          %MeetingTypeSchema{},
          Map.put(valid_attrs(), :slot_interval_minutes, 5)
        )

      assert changeset.valid?
      assert Changeset.get_change(changeset, :slot_interval_minutes) == 5
    end

    test "accepts an interval longer than the duration" do
      changeset =
        MeetingTypeSchema.changeset(
          %MeetingTypeSchema{},
          Map.put(valid_attrs(), :slot_interval_minutes, 60)
        )

      assert changeset.valid?
    end

    test "accepts a value that does not divide the hour" do
      changeset =
        MeetingTypeSchema.changeset(
          %MeetingTypeSchema{},
          Map.put(valid_attrs(), :slot_interval_minutes, 7)
        )

      assert changeset.valid?
    end

    test "rejects an interval below the floor" do
      changeset =
        MeetingTypeSchema.changeset(
          %MeetingTypeSchema{},
          Map.put(valid_attrs(), :slot_interval_minutes, 4)
        )

      refute changeset.valid?
      assert "must be greater than or equal to 5" in errors_on(changeset).slot_interval_minutes
    end

    test "rejects an interval above the ceiling" do
      changeset =
        MeetingTypeSchema.changeset(
          %MeetingTypeSchema{},
          Map.put(valid_attrs(), :slot_interval_minutes, 481)
        )

      refute changeset.valid?
      assert "must be less than or equal to 480" in errors_on(changeset).slot_interval_minutes
    end
  end

  defp valid_attrs do
    %{name: "Intro call", duration_minutes: 30, user_id: 1}
  end
end
