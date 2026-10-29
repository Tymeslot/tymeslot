defmodule Tymeslot.Integrations.HealthCheck.IntegrationHealthStateSchemaTest do
  use Tymeslot.DataCase, async: true

  @moduletag :database
  @moduletag :schema

  import Ecto.Changeset
  import Tymeslot.TestFixtures

  alias Tymeslot.Integrations.HealthCheck.IntegrationHealthStateSchema
  alias Tymeslot.Integrations.Shared.IntegrationTypes

  setup do
    user = create_user_fixture()
    %{user: user}
  end

  describe "changeset/2" do
    test "valid with required fields", %{user: user} do
      attrs = %{
        integration_type: :calendar,
        integration_id: 1,
        user_id: user.id,
        status: :healthy
      }

      changeset =
        IntegrationHealthStateSchema.changeset(%IntegrationHealthStateSchema{}, attrs)

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

    test "applies default values", %{user: user} do
      changeset =
        IntegrationHealthStateSchema.changeset(%IntegrationHealthStateSchema{}, %{
          integration_type: :calendar,
          integration_id: 1,
          user_id: user.id
        })

      assert get_field(changeset, :status) == :healthy
      assert get_field(changeset, :failures) == 0
      assert get_field(changeset, :successes) == 0
      assert get_field(changeset, :backoff_ms) == 1_800_000
    end

    test "unique constraint on integration_type and integration_id", %{user: user} do
      attrs = %{
        integration_type: :calendar,
        integration_id: 1,
        user_id: user.id,
        status: :healthy
      }

      {:ok, _state} =
        %IntegrationHealthStateSchema{}
        |> IntegrationHealthStateSchema.changeset(attrs)
        |> Repo.insert()

      {:error, changeset} =
        %IntegrationHealthStateSchema{}
        |> IntegrationHealthStateSchema.changeset(attrs)
        |> Repo.insert()

      assert "has already been taken" in errors_on(changeset).integration_type
    end

    test "rejects an integration type or error class outside the vocabulary", %{user: user} do
      changeset =
        IntegrationHealthStateSchema.changeset(%IntegrationHealthStateSchema{}, %{
          integration_type: "calender",
          integration_id: 1,
          user_id: user.id,
          last_error_class: "fatal"
        })

      assert %{integration_type: ["is invalid"], last_error_class: ["is invalid"]} =
               errors_on(changeset)
    end
  end

  test "integration_type accepts exactly the integration kinds" do
    assert Ecto.Enum.values(IntegrationHealthStateSchema, :integration_type) ==
             IntegrationTypes.kinds()
  end
end
