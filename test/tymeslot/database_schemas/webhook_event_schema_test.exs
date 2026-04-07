defmodule Tymeslot.Webhooks.WebhookEventSchemaTest do
  use Tymeslot.DataCase, async: true

  @moduletag :schema
  @moduletag :payments

  alias Tymeslot.Webhooks.WebhookEventSchema

  @valid_attrs %{
    stripe_event_id: "evt_abc123",
    event_type: "checkout.session.completed",
    processed_at: ~U[2026-03-29 12:00:00Z]
  }

  describe "changeset/2" do
    test "valid with required fields" do
      changeset = WebhookEventSchema.changeset(%WebhookEventSchema{}, @valid_attrs)
      assert changeset.valid?
    end

    test "invalid without required fields" do
      changeset = WebhookEventSchema.changeset(%WebhookEventSchema{}, %{})
      refute changeset.valid?

      assert %{
               stripe_event_id: ["can't be blank"],
               event_type: ["can't be blank"],
               processed_at: ["can't be blank"]
             } = errors_on(changeset)
    end

    test "accepts optional payload" do
      attrs = Map.put(@valid_attrs, :payload, %{"data" => %{"object" => %{"id" => "sub_123"}}})
      changeset = WebhookEventSchema.changeset(%WebhookEventSchema{}, attrs)
      assert changeset.valid?
    end

    test "valid without payload" do
      changeset = WebhookEventSchema.changeset(%WebhookEventSchema{}, @valid_attrs)
      assert changeset.valid?
      refute Map.has_key?(errors_on(changeset), :payload)
    end

    test "unique constraint on stripe_event_id" do
      {:ok, _existing} =
        %WebhookEventSchema{}
        |> WebhookEventSchema.changeset(@valid_attrs)
        |> Repo.insert()

      {:error, changeset} =
        %WebhookEventSchema{}
        |> WebhookEventSchema.changeset(@valid_attrs)
        |> Repo.insert()

      assert "has already been taken" in errors_on(changeset).stripe_event_id
    end
  end
end
