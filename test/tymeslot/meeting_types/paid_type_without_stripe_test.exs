defmodule Tymeslot.MeetingTypes.PaidTypeWithoutStripeTest do
  @moduledoc """
  What happens to a paid meeting type while its host cannot accept charges,
  which is the state a Stripe disconnect or a `charges_enabled: false` account
  update leaves behind.

  The price is kept, so it resumes on reconnect rather than being cleared
  behind the host's back. That only works if the form stops reading the absent
  payment inputs as "make it free", and if the changeset stops failing every
  unrelated save over the stored flag.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :meeting_types
  @moduletag :payments

  import Tymeslot.ConfigTestHelpers

  alias Tymeslot.MeetingTypes

  setup do
    setup_config(:tymeslot,
      feature_access_checker: Tymeslot.Features.DefaultAccessChecker,
      meeting_payments_enabled: true
    )
  end

  describe "when a paid meeting type is edited while Stripe is unavailable" do
    # The form omits the payment inputs entirely when the host cannot accept
    # charges, and reading that absence as "make it free" cleared the price on
    # the next unrelated save, silently, so the host had to re-enter every
    # price after reconnecting.
    test "an edit that posts no payment fields leaves the price alone" do
      user = insert(:user)
      meeting_type = insert(:meeting_type, user: user, payment_required: true, price_cents: 2500)

      form_params = %{
        "name" => "Renamed",
        "duration" => "45",
        "is_active" => "true"
      }

      assert {:ok, updated} =
               MeetingTypes.update_meeting_type_from_form(
                 meeting_type,
                 form_params,
                 personal_ui_state()
               )

      assert updated.name == "Renamed"
      assert updated.duration_minutes == 45
      assert updated.payment_required == true
      assert updated.price_cents == 2500
    end

    # `validate_payment_fields/2` reads the stored `true` with `get_field`, so
    # preserving it would otherwise fail every save with "Stripe must be
    # connected" — on a control the form cannot render in this state.
    test "the save is not blocked by the host having no charges-enabled account" do
      user = insert(:user)
      meeting_type = insert(:meeting_type, user: user, payment_required: true, price_cents: 2500)

      form_params =
        paid_form_params(%{
          "name" => meeting_type.name,
          "duration" => to_string(meeting_type.duration_minutes),
          "price" => "25.00"
        })

      assert {:ok, updated} =
               MeetingTypes.update_meeting_type_from_form(
                 meeting_type,
                 form_params,
                 personal_ui_state()
               )

      assert updated.payment_required == true
      assert updated.price_cents == 2500
    end

    test "turning payment on still requires a charges-enabled account" do
      user = insert(:user)
      meeting_type = insert(:meeting_type, user: user, payment_required: false, price_cents: nil)

      form_params =
        paid_form_params(%{
          "name" => meeting_type.name,
          "duration" => to_string(meeting_type.duration_minutes),
          "price" => "25.00"
        })

      assert {:error, changeset} =
               MeetingTypes.update_meeting_type_from_form(
                 meeting_type,
                 form_params,
                 personal_ui_state()
               )

      assert "Stripe must be connected" in errors_on(changeset).payment_required
    end
  end

  defp paid_form_params(overrides) do
    Map.merge(
      %{
        "name" => "Paid Consultation",
        "duration" => "30",
        "description" => "A paid session",
        "is_active" => "true",
        "payment_required" => "true"
      },
      overrides
    )
  end

  defp personal_ui_state do
    %{
      meeting_mode: "personal",
      selected_icon: "hero-clock",
      selected_video_integration_id: nil
    }
  end
end
