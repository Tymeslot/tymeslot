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
    # Every field in the booking spec has to be present and valid: on a
    # validation error `sanitize_params/2` falls back to the raw input, so
    # omitting the required email would leave the sanitiser untested.
    params = %{"name" => "  John Doe  ", "email" => "  john@example.com  "}

    {:ok, updated} = FormValidationHandlerComponent.sanitize_params(socket, params)
    assert updated.assigns.form.params["name"] == "John Doe"
    assert updated.assigns.form.params["email"] == "john@example.com"
  end

  # Regression: issue #83. The shipped TLD snapshot was missing .homes, so a
  # visitor with that address could not book. The snapshot is synced from IANA
  # now (mix tymeslot.sync_tlds).
  test "accepts an email on a TLD delegated after the list was first written" do
    socket = %Socket{
      assigns: %{__changed__: %{}, validation_errors: %{}, touched_fields: MapSet.new()}
    }

    email = "owner@eastvalleyliving.homes"

    assert {:ok, field_checked} =
             FormValidationHandlerComponent.validate_field(socket, "email", email)

    assert field_checked.assigns.validation_errors == %{}

    assert {:ok, form_checked} =
             FormValidationHandlerComponent.validate_form(socket, %{
               "name" => "Test Attendee",
               "email" => email
             })

    assert form_checked.assigns.validation_errors == %{}
    assert form_checked.assigns.form.params["email"] == email
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
