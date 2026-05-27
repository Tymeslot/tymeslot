defmodule Tymeslot.Analytics.EventSchemaTest do
  use Tymeslot.DataCase, async: true

  @moduletag :database
  @moduletag :schema

  alias Tymeslot.Analytics.EventSchema

  @valid_attrs %{
    event_type: "booking_page_view",
    path: "/alice/intro-call",
    visitor_hash: "abc123",
    tracking_params: %{}
  }

  describe "changeset/2" do
    test "is valid with minimum required fields" do
      changeset = EventSchema.changeset(%EventSchema{}, @valid_attrs)
      assert changeset.valid?
    end

    test "requires event_type" do
      changeset = EventSchema.changeset(%EventSchema{}, Map.delete(@valid_attrs, :event_type))
      refute changeset.valid?
      assert %{event_type: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires path" do
      changeset = EventSchema.changeset(%EventSchema{}, Map.delete(@valid_attrs, :path))
      refute changeset.valid?
      assert %{path: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires visitor_hash" do
      changeset = EventSchema.changeset(%EventSchema{}, Map.delete(@valid_attrs, :visitor_hash))
      refute changeset.valid?
      assert %{visitor_hash: ["can't be blank"]} = errors_on(changeset)
    end

    test "rejects unknown event_type values" do
      changeset = EventSchema.changeset(%EventSchema{}, %{@valid_attrs | event_type: "bogus"})
      refute changeset.valid?
      assert %{event_type: ["is invalid"]} = errors_on(changeset)
    end

    test "casts tracking_params as a map" do
      attrs = %{@valid_attrs | tracking_params: %{"ref" => "newsletter", "promo" => "x"}}
      changeset = EventSchema.changeset(%EventSchema{}, attrs)
      assert changeset.valid?
      assert get_change(changeset, :tracking_params) == %{"ref" => "newsletter", "promo" => "x"}
    end
  end
end
