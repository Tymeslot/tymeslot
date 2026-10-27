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
  alias Tymeslot.Repo

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

  # Checkout still charges a stored price in a legacy currency (one outside
  # the allowlist but counted in hundredths), so the account counts as
  # charges-enabled; the form offers no price controls in that state, and the
  # domain must refuse a submit that carries them anyway.
  describe "when the host's Stripe account is in a legacy currency" do
    test "a submit that sets a price on a free meeting type is refused" do
      user = insert(:user)
      charges_enabled_account(user, "ron")
      meeting_type = insert(:meeting_type, user: user, payment_required: false, price_cents: nil)

      assert {:error, changeset} =
               MeetingTypes.update_meeting_type_from_form(
                 meeting_type,
                 price_params(meeting_type, "25.00"),
                 personal_ui_state()
               )

      assert "Prices cannot be set in your Stripe account's currency" in errors_on(changeset).payment_required

      assert %{payment_required: false, price_cents: nil} = Repo.reload!(meeting_type)
    end

    test "a submit that changes a stored price is refused" do
      user = insert(:user)
      charges_enabled_account(user, "ron")
      meeting_type = insert(:meeting_type, user: user, payment_required: true, price_cents: 2500)

      assert {:error, changeset} =
               MeetingTypes.update_meeting_type_from_form(
                 meeting_type,
                 price_params(meeting_type, "40.00"),
                 personal_ui_state()
               )

      assert "Prices cannot be set in your Stripe account's currency" in errors_on(changeset).payment_required

      assert %{payment_required: true, price_cents: 2500} = Repo.reload!(meeting_type)
    end

    test "a new meeting type cannot be created with a price" do
      user = insert(:user)
      charges_enabled_account(user, "ron")

      assert {:error, changeset} =
               MeetingTypes.create_meeting_type_from_form(
                 user.id,
                 paid_form_params(%{"price" => "25.00"}),
                 personal_ui_state()
               )

      assert "Prices cannot be set in your Stripe account's currency" in errors_on(changeset).payment_required
    end

    test "turning payment off is still allowed" do
      user = insert(:user)
      charges_enabled_account(user, "ron")
      meeting_type = insert(:meeting_type, user: user, payment_required: true, price_cents: 2500)

      params =
        meeting_type
        |> price_params("")
        |> Map.put("payment_required", "false")

      assert {:ok, %{payment_required: false, price_cents: nil}} =
               MeetingTypes.update_meeting_type_from_form(
                 meeting_type,
                 params,
                 personal_ui_state()
               )
    end

    test "a host in a supported currency still changes their price" do
      user = insert(:user)
      charges_enabled_account(user, "chf")
      meeting_type = insert(:meeting_type, user: user, payment_required: true, price_cents: 2500)

      assert {:ok, %{payment_required: true, price_cents: 4000}} =
               MeetingTypes.update_meeting_type_from_form(
                 meeting_type,
                 price_params(meeting_type, "40.00"),
                 personal_ui_state()
               )
    end
  end

  defp charges_enabled_account(user, currency) do
    insert(:connect_account,
      user: user,
      default_currency: currency,
      charges_enabled: true,
      payouts_enabled: true,
      details_submitted: true
    )
  end

  defp price_params(meeting_type, price) do
    paid_form_params(%{
      "name" => meeting_type.name,
      "duration" => to_string(meeting_type.duration_minutes),
      "price" => price
    })
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
