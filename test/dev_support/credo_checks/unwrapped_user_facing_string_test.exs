Code.require_file(
  "dev_support/credo_checks/unwrapped_user_facing_string.ex",
  Path.join(__DIR__, "../../..")
)

defmodule CredoChecks.UnwrappedUserFacingStringTest do
  use Credo.Test.Case, async: false

  alias CredoChecks.UnwrappedUserFacingString

  @moduletag :dev_support

  setup_all do
    Application.ensure_all_started(:credo)
    :ok
  end

  describe "flash literals are flagged" do
    test "put_flash/3 with a string literal is flagged" do
      """
      defmodule TymeslotWeb.Page do
        def go(conn), do: put_flash(conn, :error, "Please try again.")
      end
      """
      |> to_source_file("lib/tymeslot_web/page.ex")
      |> run_check(UnwrappedUserFacingString)
      |> assert_issue(fn issue -> assert issue.trigger == "Please try again." end)
    end

    test "piped put_flash/2 with a string literal is flagged" do
      """
      defmodule TymeslotWeb.Page do
        def go(socket), do: socket |> put_flash(:info, "Saved your changes")
      end
      """
      |> to_source_file("lib/tymeslot_web/page.ex")
      |> run_check(UnwrappedUserFacingString)
      |> assert_issue(fn issue -> assert issue.trigger == "Saved your changes" end)
    end

    test "Flash.error/1 with a string literal is flagged" do
      """
      defmodule TymeslotWeb.Page do
        alias TymeslotWeb.Live.Shared.Flash
        def go, do: Flash.error("Something went wrong.")
      end
      """
      |> to_source_file("lib/tymeslot_web/page.ex")
      |> run_check(UnwrappedUserFacingString)
      |> assert_issue(fn issue -> assert issue.trigger == "Something went wrong." end)
    end

    test "Controller.put_flash/3 with a string literal is flagged" do
      """
      defmodule TymeslotWeb.Plugs.RequireAuthPlug do
        alias Phoenix.Controller
        def go(conn), do: Controller.put_flash(conn, :error, "You must be logged in to access this page.")
      end
      """
      |> to_source_file("lib/tymeslot_web/plugs/require_auth.ex")
      |> run_check(UnwrappedUserFacingString)
      |> assert_issue(fn issue ->
        assert issue.trigger == "You must be logged in to access this page."
      end)
    end

    test "piped LiveView.put_flash/2 with a string literal is flagged" do
      """
      defmodule TymeslotWeb.Themes.Shared.PaymentReturn do
        alias Phoenix.LiveView
        def go(socket), do: socket |> LiveView.put_flash(:error, "Payment not found.")
      end
      """
      |> to_source_file("lib/tymeslot_web/themes/shared/payment_return.ex")
      |> run_check(UnwrappedUserFacingString)
      |> assert_issue(fn issue -> assert issue.trigger == "Payment not found." end)
    end

    test "fully-qualified Phoenix.LiveView.put_flash/3 with a string literal is flagged" do
      """
      defmodule TymeslotWeb.Page do
        def go(socket), do: Phoenix.LiveView.put_flash(socket, :error, "Something went wrong.")
      end
      """
      |> to_source_file("lib/tymeslot_web/page.ex")
      |> run_check(UnwrappedUserFacingString)
      |> assert_issue(fn issue -> assert issue.trigger == "Something went wrong." end)
    end
  end

  describe "flash calls that already localise are not flagged" do
    test "put_flash with dgettext is not flagged" do
      """
      defmodule TymeslotWeb.Page do
        def go(conn), do: put_flash(conn, :error, dgettext("auth", "Please try again."))
      end
      """
      |> to_source_file("lib/tymeslot_web/page.ex")
      |> run_check(UnwrappedUserFacingString)
      |> refute_issues()
    end

    test "Controller.put_flash with dgettext is not flagged" do
      """
      defmodule TymeslotWeb.Plugs.RequireAuthPlug do
        alias Phoenix.Controller
        def go(conn), do: Controller.put_flash(conn, :error, dgettext("auth", "Please try again."))
      end
      """
      |> to_source_file("lib/tymeslot_web/plugs/require_auth.ex")
      |> run_check(UnwrappedUserFacingString)
      |> refute_issues()
    end

    test "piped LiveView.put_flash with dgettext is not flagged" do
      """
      defmodule TymeslotWeb.Themes.Shared.PaymentReturn do
        alias Phoenix.LiveView
        def go(socket), do: socket |> LiveView.put_flash(:error, dgettext("booking", "Payment not found."))
      end
      """
      |> to_source_file("lib/tymeslot_web/themes/shared/payment_return.ex")
      |> run_check(UnwrappedUserFacingString)
      |> refute_issues()
    end

    test "Controller.put_flash with dgettext_noop is not flagged" do
      """
      defmodule TymeslotWeb.Plugs.RequireAuthPlug do
        alias Phoenix.Controller
        def go(conn), do: Controller.put_flash(conn, :error, dgettext_noop("Please try again."))
      end
      """
      |> to_source_file("lib/tymeslot_web/plugs/require_auth.ex")
      |> run_check(UnwrappedUserFacingString)
      |> refute_issues()
    end

    test "LiveView.put_flash with an interpolated string is not flagged" do
      """
      defmodule TymeslotWeb.Page do
        def go(socket, name), do: LiveView.put_flash(socket, :error, "Failed for \#{name}")
      end
      """
      |> to_source_file("lib/tymeslot_web/page.ex")
      |> run_check(UnwrappedUserFacingString)
      |> refute_issues()
    end

    test "Controller.put_flash with a pinned assign is not flagged" do
      """
      defmodule TymeslotWeb.Page do
        def go(conn, message), do: Controller.put_flash(conn, :error, message)
      end
      """
      |> to_source_file("lib/tymeslot_web/page.ex")
      |> run_check(UnwrappedUserFacingString)
      |> refute_issues()
    end

    test "put_flash routed through a helper function is not flagged" do
      """
      defmodule TymeslotWeb.Page do
        def go(conn, reason), do: put_flash(conn, :error, error_message(reason))
      end
      """
      |> to_source_file("lib/tymeslot_web/page.ex")
      |> run_check(UnwrappedUserFacingString)
      |> refute_issues()
    end

    test "a single-token flash value is not flagged" do
      """
      defmodule TymeslotWeb.Page do
        def go(conn), do: put_flash(conn, :error, "saved")
      end
      """
      |> to_source_file("lib/tymeslot_web/page.ex")
      |> run_check(UnwrappedUserFacingString)
      |> refute_issues()
    end
  end

  describe "attr defaults" do
    test "a prose attr default is flagged" do
      """
      defmodule TymeslotWeb.Component do
        attr :confirm_text, :string, default: "Are you sure?"
      end
      """
      |> to_source_file("lib/tymeslot_web/component.ex")
      |> run_check(UnwrappedUserFacingString)
      |> assert_issue(fn issue -> assert issue.trigger == "Are you sure?" end)
    end

    test "an ellipsis-terminated single word is flagged" do
      """
      defmodule TymeslotWeb.Component do
        attr :loading_text, :string, default: "Processing..."
      end
      """
      |> to_source_file("lib/tymeslot_web/component.ex")
      |> run_check(UnwrappedUserFacingString)
      |> assert_issue(fn issue -> assert issue.trigger == "Processing..." end)
    end

    test "a CSS utility-class default is NOT flagged" do
      """
      defmodule TymeslotWeb.Component do
        attr :class, :string, default: "btn btn-primary w-5 h-5"
      end
      """
      |> to_source_file("lib/tymeslot_web/component.ex")
      |> run_check(UnwrappedUserFacingString)
      |> refute_issues()
    end

    test "a Tailwind default with variants is NOT flagged" do
      """
      defmodule TymeslotWeb.Component do
        attr :class, :string, default: "absolute top-0 right-0 hover:bg-red-500"
      end
      """
      |> to_source_file("lib/tymeslot_web/component.ex")
      |> run_check(UnwrappedUserFacingString)
      |> refute_issues()
    end

    test "a single-token default is NOT flagged" do
      """
      defmodule TymeslotWeb.Component do
        attr :layout, :string, default: "column"
      end
      """
      |> to_source_file("lib/tymeslot_web/component.ex")
      |> run_check(UnwrappedUserFacingString)
      |> refute_issues()
    end

    test "an attr without a default is NOT flagged" do
      """
      defmodule TymeslotWeb.Component do
        attr :title, :string, required: true
      end
      """
      |> to_source_file("lib/tymeslot_web/component.ex")
      |> run_check(UnwrappedUserFacingString)
      |> refute_issues()
    end
  end

  describe "excluded paths" do
    test "the SaaS overlay is excluded" do
      """
      defmodule TymeslotSaasWeb.Page do
        def go(conn), do: put_flash(conn, :error, "No active subscription found.")
      end
      """
      |> to_source_file("apps/tymeslot_saas/lib/tymeslot_saas_web/page.ex")
      |> run_check(UnwrappedUserFacingString)
      |> refute_issues()
    end

    test "the Core marketing header/footer is excluded" do
      """
      defmodule TymeslotWeb.SiteComponents do
        def go(conn), do: put_flash(conn, :info, "Thanks for signing up!")
      end
      """
      |> to_source_file("lib/tymeslot_web/components/site_components.ex")
      |> run_check(UnwrappedUserFacingString)
      |> refute_issues()
    end

    test "test files are excluded" do
      """
      defmodule TymeslotWeb.PageTest do
        def go(conn), do: put_flash(conn, :error, "Please try again.")
      end
      """
      |> to_source_file("test/tymeslot_web/page_test.exs")
      |> run_check(UnwrappedUserFacingString)
      |> refute_issues()
    end
  end
end
