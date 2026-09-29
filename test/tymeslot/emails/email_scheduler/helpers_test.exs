defmodule Tymeslot.Emails.EmailScheduler.HelpersTest do
  use ExUnit.Case, async: true

  @moduletag :emails
  @moduletag :unit

  alias Ecto.Changeset
  alias Tymeslot.Emails.EmailScheduler.Helpers

  describe "format_insert_error/1" do
    test "traverses changeset errors into a plain map" do
      changeset =
        {%{}, %{name: :string}}
        |> Changeset.cast(%{}, [:name])
        |> Changeset.validate_required([:name])

      assert %{name: ["can't be blank"]} = Helpers.format_insert_error(changeset)
    end

    test "inspects non-changeset terms as strings" do
      assert Helpers.format_insert_error(:some_error) == ":some_error"
      assert Helpers.format_insert_error("raw string") == ~s("raw string")
      assert Helpers.format_insert_error({:error, 404}) == "{:error, 404}"
    end

    test "redacts a credential inside a non-changeset term" do
      formatted = Helpers.format_insert_error({:error, %{"api_key" => "sk-leak", code: 500}})

      assert formatted =~ "[REDACTED]"
      assert formatted =~ "500"
      refute formatted =~ "sk-leak"
    end
  end
end
