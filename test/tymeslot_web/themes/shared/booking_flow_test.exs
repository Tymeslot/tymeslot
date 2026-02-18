defmodule TymeslotWeb.Themes.Shared.BookingFlowTest do
  use TymeslotWeb.ConnCase, async: true
  @moduletag :utils

  alias Phoenix.LiveView.Socket
  alias TymeslotWeb.Themes.Shared.BookingFlow

  test "does not show validation errors before form is touched" do
    socket = %Socket{assigns: %{__changed__: %{}}}

    params = %{
      "name" => "",
      "email" => "invalid",
      "message" => ""
    }

    {:noreply, updated} = BookingFlow.handle_form_validation(socket, params)

    assert updated.assigns.validation_errors == %{}
    assert updated.assigns.form_touched == false
  end

  test "assigns validation errors after user interaction" do
    socket = %Socket{assigns: %{__changed__: %{}}}

    params = %{
      "name" => "",
      "email" => "invalid",
      "message" => "",
      "_target" => ["booking", "email"]
    }

    {:noreply, updated} = BookingFlow.handle_form_validation(socket, params)

    assert updated.assigns.form_touched == true
    assert map_size(updated.assigns.validation_errors) > 0
    assert Map.has_key?(updated.assigns.validation_errors, :email)
  end

  test "keeps form touched across subsequent validations" do
    socket = %Socket{assigns: %{__changed__: %{}}}

    params = %{
      "name" => "",
      "email" => "invalid",
      "message" => "",
      "_target" => ["booking", "email"]
    }

    {:noreply, touched} = BookingFlow.handle_form_validation(socket, params)
    assert touched.assigns.form_touched == true

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
