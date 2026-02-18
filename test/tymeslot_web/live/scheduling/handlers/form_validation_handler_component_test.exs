defmodule TymeslotWeb.Live.Scheduling.Handlers.FormValidationHandlerComponentTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :utils

  alias Phoenix.LiveView.Socket
  alias TymeslotWeb.Live.Scheduling.Handlers.FormValidationHandlerComponent

  test "validate_form/2 handles valid data" do
    socket = %Socket{assigns: %{__changed__: %{}, touched_fields: MapSet.new()}}
    params = %{"name" => "John Doe", "email" => "john@example.com"}

    {:ok, updated} = FormValidationHandlerComponent.validate_form(socket, params)
    assert updated.assigns.form.params["name"] == "John Doe"
    assert updated.assigns.validation_errors == %{}
  end

  test "validate_form/2 handles invalid data" do
    socket = %Socket{assigns: %{__changed__: %{}, touched_fields: MapSet.new([:name])}}
    params = %{"name" => "", "email" => "john@example.com"}

    {:error, updated} = FormValidationHandlerComponent.validate_form(socket, params)
    assert updated.assigns.validation_errors != %{}
  end

  test "sanitize_params/2 sanitizes data" do
    socket = %Socket{assigns: %{__changed__: %{}}}
    params = %{"name" => "  John Doe  "}

    {:ok, updated} = FormValidationHandlerComponent.sanitize_params(socket, params)
    assert updated.assigns.form.params["name"] == "  John Doe  "
  end

  test "validate_field/3 validates fields" do
    socket = %Socket{assigns: %{__changed__: %{}, validation_errors: %{}}}

    {:error, updated} = FormValidationHandlerComponent.validate_field(socket, "email", "invalid")
    assert Map.has_key?(updated.assigns.validation_errors, "email")

    {:ok, updated_valid} =
      FormValidationHandlerComponent.validate_field(updated, "email", "john@example.com")

    assert updated_valid.assigns.validation_errors == %{}
  end
end
