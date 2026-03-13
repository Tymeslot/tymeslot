defmodule TymeslotWeb.Themes.Shared.BookingFlowTest do
  use TymeslotWeb.ConnCase, async: true
  @moduletag :utils

  alias Phoenix.LiveView.Socket
  alias TymeslotWeb.Live.Shared.FormValidationHelpers
  alias TymeslotWeb.Themes.Shared.BookingFlow

  # Helper to build a socket with touched_fields pre-populated,
  # matching what Helpers.mark_field_touched/2 does on field_blur.
  defp socket_with_touched_fields(fields) do
    %Socket{assigns: %{__changed__: %{}, touched_fields: MapSet.new(fields)}}
  end

  defp untouched_socket do
    %Socket{assigns: %{__changed__: %{}}}
  end

  test "does not show validation errors before form is touched" do
    params = %{"name" => "", "email" => "invalid", "message" => ""}

    {:noreply, updated} = BookingFlow.handle_form_validation(untouched_socket(), params)

    assert updated.assigns.validation_errors == %{}
    assert updated.assigns.form_touched == false
  end

  test "only shows errors for touched fields, not untouched ones" do
    # User blurred only the email field — name errors should not appear
    socket = socket_with_touched_fields(["email"])
    params = %{"name" => "", "email" => "invalid", "message" => ""}

    {:noreply, updated} = BookingFlow.handle_form_validation(socket, params)

    assert updated.assigns.form_touched == true

    # Email was touched and is invalid — error shown
    assert FormValidationHelpers.field_errors(updated.assigns.validation_errors, :email) != []

    # Name was NOT touched — error must NOT appear even though it's invalid
    assert FormValidationHelpers.field_errors(updated.assigns.validation_errors, :name) == []
  end

  test "shows errors for each field independently as they are touched" do
    # User blurs name first
    socket = socket_with_touched_fields(["name"])
    params = %{"name" => "L", "email" => "invalid", "message" => ""}

    {:noreply, after_name} = BookingFlow.handle_form_validation(socket, params)

    # Only name error visible
    assert FormValidationHelpers.field_errors(after_name.assigns.validation_errors, :name) == [
             "Name is too short (minimum 2 characters)"
           ]

    assert FormValidationHelpers.field_errors(after_name.assigns.validation_errors, :email) == []

    # User then blurs email — now both fields show errors
    after_name_and_email =
      %{after_name | assigns: Map.put(after_name.assigns, :touched_fields, MapSet.new(["name", "email"]))}

    {:noreply, after_both} = BookingFlow.handle_form_validation(after_name_and_email, params)

    assert FormValidationHelpers.field_errors(after_both.assigns.validation_errors, :name) != []
    assert FormValidationHelpers.field_errors(after_both.assigns.validation_errors, :email) != []
  end

  test "errors clear when user corrects input" do
    socket = socket_with_touched_fields(["name"])

    # First validation — name too short
    {:noreply, with_error} =
      BookingFlow.handle_form_validation(socket, %{
        "name" => "L",
        "email" => "valid@example.com",
        "message" => ""
      })

    assert FormValidationHelpers.field_errors(with_error.assigns.validation_errors, :name) != []

    # User corrects name — error should clear
    {:noreply, corrected} =
      BookingFlow.handle_form_validation(with_error, %{
        "name" => "Luka",
        "email" => "valid@example.com",
        "message" => ""
      })

    assert corrected.assigns.validation_errors == %{}
    assert FormValidationHelpers.field_errors(corrected.assigns.validation_errors, :name) == []
  end

  test "keeps form touched across subsequent validations" do
    socket = socket_with_touched_fields(["email"])
    params = %{"name" => "", "email" => "invalid", "message" => ""}

    {:noreply, touched} = BookingFlow.handle_form_validation(socket, params)
    assert touched.assigns.form_touched == true

    # Subsequent validation still shows errors because form_touched persists
    {:noreply, updated} =
      BookingFlow.handle_form_validation(touched, %{
        "name" => "",
        "email" => "invalid",
        "message" => ""
      })

    assert updated.assigns.form_touched == true
    assert map_size(updated.assigns.validation_errors) > 0
  end
end
