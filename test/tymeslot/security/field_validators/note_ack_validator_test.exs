defmodule Tymeslot.Security.FieldValidators.NoteAckValidatorTest do
  use Tymeslot.DataCase, async: true

  @moduletag :security

  alias Tymeslot.Security.FieldValidators.NoteAckValidator

  describe "validate/3" do
    test "confirmed: true with valid iso timestamp is ok" do
      ts = DateTime.to_iso8601(DateTime.utc_now())
      assert :ok = NoteAckValidator.validate(%{"confirmed" => true, "confirmed_at" => ts}, %{})
    end

    test "confirmed: false is rejected" do
      ts = DateTime.to_iso8601(DateTime.utc_now())

      assert {:error, _msg} =
               NoteAckValidator.validate(%{"confirmed" => false, "confirmed_at" => ts}, %{})
    end

    test "missing confirmed key is rejected" do
      assert {:error, _msg} = NoteAckValidator.validate(%{"confirmed_at" => "..."}, %{})
    end

    test "missing confirmed_at is rejected" do
      assert {:error, _msg} = NoteAckValidator.validate(%{"confirmed" => true}, %{})
    end

    test "non-iso timestamp rejected" do
      assert {:error, _msg} =
               NoteAckValidator.validate(
                 %{"confirmed" => true, "confirmed_at" => "yesterday"},
                 %{}
               )
    end

    test "nil value rejected" do
      assert {:error, _msg} = NoteAckValidator.validate(nil, %{})
    end

    test "non-map rejected" do
      assert {:error, _msg} = NoteAckValidator.validate("yes", %{})
    end

    test "integer timestamp rejected" do
      assert {:error, _msg} =
               NoteAckValidator.validate(%{"confirmed" => true, "confirmed_at" => 1_234_567}, %{})
    end

    test "confirmed: true with confirmed_at as nil is rejected" do
      assert {:error, _msg} =
               NoteAckValidator.validate(%{"confirmed" => true, "confirmed_at" => nil}, %{})
    end

    test "non-UTC offset rejected" do
      assert {:error, _msg} =
               NoteAckValidator.validate(
                 %{"confirmed" => true, "confirmed_at" => "2026-05-13T10:00:00+05:30"},
                 %{}
               )
    end
  end
end
