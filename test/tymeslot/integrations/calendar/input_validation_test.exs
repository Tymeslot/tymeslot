defmodule Tymeslot.Integrations.Calendar.InputValidationTest do
  use Tymeslot.DataCase, async: true

  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.InputValidation

  @valid_params %{
    "name" => "Work Calendar",
    "url" => "https://caldav.example.com/",
    "username" => "user@example.com",
    "password" => "secret",
    "calendar_paths" => ""
  }

  describe "validate_calendar_integration_form/1 - password special characters" do
    test "preserves password containing >" do
      params = Map.put(@valid_params, "password", "pass>word")
      assert {:ok, result} = InputValidation.validate_calendar_integration_form(params)
      assert result["password"] == "pass>word"
    end

    test "preserves password containing <" do
      params = Map.put(@valid_params, "password", "pass<word")
      assert {:ok, result} = InputValidation.validate_calendar_integration_form(params)
      assert result["password"] == "pass<word"
    end

    test "preserves password containing &" do
      params = Map.put(@valid_params, "password", "pass&word")
      assert {:ok, result} = InputValidation.validate_calendar_integration_form(params)
      assert result["password"] == "pass&word"
    end

    test "preserves password with multiple HTML-special characters" do
      params = Map.put(@valid_params, "password", "P@ss<w0rd>&\"me\"")
      assert {:ok, result} = InputValidation.validate_calendar_integration_form(params)
      assert result["password"] == "P@ss<w0rd>&\"me\""
    end

    test "preserves password with SQL-like content" do
      params = Map.put(@valid_params, "password", "pass--word")
      assert {:ok, result} = InputValidation.validate_calendar_integration_form(params)
      assert result["password"] == "pass--word"
    end
  end

  describe "validate_calendar_integration_form/1 - password validation" do
    test "rejects nil password" do
      params = Map.put(@valid_params, "password", nil)
      assert {:error, %{password: _errors}} = InputValidation.validate_calendar_integration_form(params)
    end

    test "rejects empty password" do
      params = Map.put(@valid_params, "password", "")
      assert {:error, %{password: _errors}} = InputValidation.validate_calendar_integration_form(params)
    end

    test "rejects whitespace-only password" do
      params = Map.put(@valid_params, "password", "   ")
      assert {:error, %{password: _errors}} = InputValidation.validate_calendar_integration_form(params)
    end

    test "rejects password over 500 characters" do
      params = Map.put(@valid_params, "password", String.duplicate("a", 501))
      assert {:error, %{password: _errors}} = InputValidation.validate_calendar_integration_form(params)
    end

    test "accepts password of exactly 500 characters" do
      params = Map.put(@valid_params, "password", String.duplicate("a", 500))
      assert {:ok, result} = InputValidation.validate_calendar_integration_form(params)
      assert String.length(result["password"]) == 500
    end
  end

  describe "validate_calendar_integration_form/1 - password edge cases" do
    test "rejects password with invalid UTF-8 encoding" do
      params = Map.put(@valid_params, "password", <<0xFF, 0xFE, 0x00>>)
      assert {:error, %{password: _errors}} = InputValidation.validate_calendar_integration_form(params)
    end

    test "rejects password containing null bytes" do
      params = Map.put(@valid_params, "password", "pass\x00word")
      assert {:error, %{password: _errors}} = InputValidation.validate_calendar_integration_form(params)
    end

    test "preserves leading and trailing whitespace in password" do
      params = Map.put(@valid_params, "password", "  secret  ")
      assert {:ok, result} = InputValidation.validate_calendar_integration_form(params)
      assert result["password"] == "  secret  "
    end
  end

  describe "validate_single_field/2 - password" do
    test "preserves special characters" do
      assert {:ok, "p@ss>w0rd<&"} =
               InputValidation.validate_single_field(:password, "p@ss>w0rd<&")
    end

    test "rejects empty password" do
      assert {:error, _errors} = InputValidation.validate_single_field(:password, "")
    end
  end
end
