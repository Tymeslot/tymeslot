defmodule Tymeslot.DatabaseSchemas.ProfileSchemaTest do
  use Tymeslot.DataCase, async: true

  @moduletag :database
  @moduletag :schema

  alias Tymeslot.DatabaseSchemas.ProfileSchema

  describe "critical business validations" do
    test "prevents invalid timezones that would break scheduling" do
      user = insert(:user)

      # Invalid timezone would cause meeting time calculation errors
      attrs = %{
        user_id: user.id,
        timezone: "Invalid/Timezone"
      }

      changeset = ProfileSchema.changeset(%ProfileSchema{}, attrs)

      refute changeset.valid?
      assert "is not a valid timezone" in errors_on(changeset).timezone
    end
  end
end
