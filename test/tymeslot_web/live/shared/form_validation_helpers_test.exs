defmodule TymeslotWeb.Live.Shared.FormValidationHelpersTest do
  use ExUnit.Case, async: true
  @moduletag :utils

  alias TymeslotWeb.Live.Shared.FormValidationHelpers

  @fields ~w(name email subject message)

  test "base_form_params builds empty map" do
    assert FormValidationHelpers.base_form_params(@fields) == %{
             "name" => "",
             "email" => "",
             "subject" => "",
             "message" => ""
           }
  end

  test "atomize_field only allows known fields" do
    assert FormValidationHelpers.atomize_field("email", @fields) == :email
    assert FormValidationHelpers.atomize_field("unknown", @fields) == nil
  end

  test "delete_field_error removes atom and string keys" do
    errors =
      %{"email" => "bad"}
      |> Map.put(:subject, "missing")
      |> Map.put(:email, "bad")

    assert FormValidationHelpers.delete_field_error(errors, :email) == %{subject: "missing"}
  end

  test "normalize_errors_map filters and normalizes keys" do
    errors = %{"email" => "bad", :subject => "missing", "nope" => "ignore"}

    assert FormValidationHelpers.normalize_errors_map(errors, @fields) == %{
             email: "bad",
             subject: "missing"
           }
  end

  test "normalize_errors_map drops unknown string keys without atomizing" do
    errors = %{"not_allowed" => "ignore"}

    assert FormValidationHelpers.normalize_errors_map(errors, @fields) == %{}
  end
end
