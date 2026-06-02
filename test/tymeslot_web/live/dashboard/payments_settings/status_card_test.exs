defmodule TymeslotWeb.Dashboard.PaymentsSettings.StatusCardTest do
  use ExUnit.Case, async: true

  @moduletag :payments
  @moduletag :components

  import Phoenix.LiveViewTest

  alias TymeslotWeb.Dashboard.PaymentsSettings.StatusCard

  defp render_card(account) do
    render_component(&StatusCard.status_card/1, account: account)
  end

  describe "status_card/1 state machine" do
    test "deleted account renders the disconnected state" do
      html = render_card(%{deleted_at: DateTime.utc_now(), default_currency: "eur"})

      assert html =~ "Disconnected"
      assert html =~ "Reconnect to accept payments again."
      refute html =~ "Connected and ready"
    end

    test "disabled_reason renders the restricted (error) state with the reason" do
      html =
        render_card(%{
          deleted_at: nil,
          disabled_reason: "rejected.fraud",
          default_currency: "eur"
        })

      assert html =~ "Restricted"
      assert html =~ "Reason: rejected.fraud"
    end

    test "charges and payouts enabled renders the connected (success) state" do
      html =
        render_card(%{
          deleted_at: nil,
          disabled_reason: nil,
          charges_enabled: true,
          payouts_enabled: true,
          details_submitted: true,
          default_currency: "eur"
        })

      assert html =~ "Connected and ready"
      assert html =~ "Charges and payouts are enabled."
      # A fully-onboarded account never shows the resume button.
      refute html =~ "Continue onboarding"
    end

    test "details submitted but charges disabled renders the pending-review (warning) state" do
      html =
        render_card(%{
          deleted_at: nil,
          disabled_reason: nil,
          charges_enabled: false,
          payouts_enabled: false,
          details_submitted: true,
          default_currency: "eur"
        })

      assert html =~ "Pending Stripe review"
      assert html =~ "Stripe is reviewing your account."
      # Nothing for the host to do while Stripe reviews — no resume button.
      refute html =~ "Continue onboarding"
    end

    test "incomplete account (no details submitted) prompts to finish onboarding with a button" do
      html =
        render_card(%{
          deleted_at: nil,
          disabled_reason: nil,
          charges_enabled: false,
          payouts_enabled: false,
          details_submitted: false,
          default_currency: "eur"
        })

      # Distinct from pending-review: nothing has been submitted to Stripe yet.
      assert html =~ "Finish connecting Stripe"
      refute html =~ "Pending Stripe review"
      # The apostrophe is HTML-escaped in the rendered output.
      assert html =~ "haven&#39;t finished onboarding yet."
      # The host can resume onboarding directly from the banner.
      assert html =~ "Continue onboarding"
      assert html =~ ~s(action="/dashboard/payments/connect")
      assert html =~ ~s(method="post")
    end
  end

  describe "needs_onboarding?/1" do
    test "true only while onboarding is incomplete" do
      incomplete = %{deleted_at: nil, disabled_reason: nil, details_submitted: false}
      submitted = %{deleted_at: nil, disabled_reason: nil, details_submitted: true}

      ready = %{
        deleted_at: nil,
        disabled_reason: nil,
        charges_enabled: true,
        payouts_enabled: true,
        details_submitted: true
      }

      assert StatusCard.needs_onboarding?(incomplete)
      refute StatusCard.needs_onboarding?(submitted)
      refute StatusCard.needs_onboarding?(ready)
    end
  end
end
