defmodule Tymeslot.DatabaseSchemas.IntegrationHealthStateSchemaTest do
  use Tymeslot.DataCase, async: true

  @moduletag :database
  @moduletag :schema

  import Ecto.Changeset

  alias Tymeslot.DatabaseSchemas.IntegrationHealthStateSchema

  @valid_attrs %{
    integration_type: "calendar",
    integration_id: 1,
    user_id: 1,
    status: "healthy"
  }

  describe "changeset/2" do
    test "valid with required fields" do
      changeset =
        IntegrationHealthStateSchema.changeset(%IntegrationHealthStateSchema{}, @valid_attrs)

      assert changeset.valid?
    end

    test "invalid without required fields" do
      changeset = IntegrationHealthStateSchema.changeset(%IntegrationHealthStateSchema{}, %{})
      refute changeset.valid?

      assert %{
               integration_type: ["can't be blank"],
               integration_id: ["can't be blank"],
               user_id: ["can't be blank"]
             } = errors_on(changeset)
    end

    test "applies default values" do
      changeset =
        IntegrationHealthStateSchema.changeset(%IntegrationHealthStateSchema{}, %{
          integration_type: "calendar",
          integration_id: 1,
          user_id: 1
        })

      assert get_field(changeset, :status) == "healthy"
      assert get_field(changeset, :failures) == 0
      assert get_field(changeset, :successes) == 0
      assert get_field(changeset, :backoff_ms) == 1_800_000
    end

    test "unique constraint on integration_type and integration_id" do
      {:ok, _state} =
        %IntegrationHealthStateSchema{}
        |> IntegrationHealthStateSchema.changeset(@valid_attrs)
        |> Repo.insert()

      {:error, changeset} =
        %IntegrationHealthStateSchema{}
        |> IntegrationHealthStateSchema.changeset(@valid_attrs)
        |> Repo.insert()

      assert "has already been taken" in errors_on(changeset).integration_type
    end
  end

  describe "upsert_changeset/2" do
    test "valid with only integration_type and integration_id" do
      attrs = %{integration_type: "video", integration_id: 5}

      changeset =
        IntegrationHealthStateSchema.upsert_changeset(%IntegrationHealthStateSchema{}, attrs)

      assert changeset.valid?
    end

    test "invalid without required fields" do
      changeset =
        IntegrationHealthStateSchema.upsert_changeset(%IntegrationHealthStateSchema{}, %{})

      refute changeset.valid?

      assert %{
               integration_type: ["can't be blank"],
               integration_id: ["can't be blank"]
             } = errors_on(changeset)
    end

    test "does not require user_id or status" do
      attrs = %{integration_type: "calendar", integration_id: 1}

      changeset =
        IntegrationHealthStateSchema.upsert_changeset(%IntegrationHealthStateSchema{}, attrs)

      assert changeset.valid?
      refute Map.has_key?(errors_on(changeset), :user_id)
      refute Map.has_key?(errors_on(changeset), :status)
    end
  end
end
