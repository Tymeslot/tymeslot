Code.require_file(
  "dev_support/credo_checks/gettext_domain_boundary.ex",
  Path.join(__DIR__, "../../..")
)

defmodule CredoChecks.GettextDomainBoundaryTest do
  use Credo.Test.Case, async: false

  alias CredoChecks.GettextDomainBoundary

  @moduletag :dev_support

  setup_all do
    Application.ensure_all_started(:credo)
    :ok
  end

  describe "bare gettext/ngettext are flagged" do
    test "gettext/1 is flagged" do
      """
      defmodule TymeslotWeb.Page do
        use Gettext, backend: TymeslotWeb.Gettext

        def title, do: gettext("Confirm your booking")
      end
      """
      |> to_source_file("lib/tymeslot_web/page.ex")
      |> run_check(GettextDomainBoundary)
      |> assert_issue(fn issue -> assert issue.trigger == "gettext" end)
    end

    test "gettext/2 with interpolation is flagged" do
      """
      defmodule TymeslotWeb.Page do
        def greet(name), do: gettext("Hi %{name}", name: name)
      end
      """
      |> to_source_file("lib/tymeslot_web/page.ex")
      |> run_check(GettextDomainBoundary)
      |> assert_issue(fn issue -> assert issue.trigger == "gettext" end)
    end

    test "ngettext/3 is flagged" do
      """
      defmodule TymeslotWeb.Page do
        def slots(n), do: ngettext("1 slot", "%{count} slots", n)
      end
      """
      |> to_source_file("lib/tymeslot_web/page.ex")
      |> run_check(GettextDomainBoundary)
      |> assert_issue(fn issue -> assert issue.trigger == "ngettext" end)
    end
  end

  describe "explicit known domains pass" do
    test "dgettext with a known domain is not flagged" do
      """
      defmodule TymeslotWeb.Page do
        def title, do: dgettext("booking", "Confirm your booking")
      end
      """
      |> to_source_file("lib/tymeslot_web/page.ex")
      |> run_check(GettextDomainBoundary)
      |> refute_issues()
    end

    test "dngettext with a known domain is not flagged" do
      """
      defmodule TymeslotWeb.Page do
        def slots(n), do: dngettext("booking", "1 slot", "%{count} slots", n)
      end
      """
      |> to_source_file("lib/tymeslot_web/page.ex")
      |> run_check(GettextDomainBoundary)
      |> refute_issues()
    end
  end

  describe "unknown domains are flagged" do
    test "dgettext with a domain outside the allowlist is flagged" do
      """
      defmodule TymeslotWeb.Page do
        def title, do: dgettext("marketing", "Pricing")
      end
      """
      |> to_source_file("lib/tymeslot_web/page.ex")
      |> run_check(GettextDomainBoundary)
      |> assert_issue(fn issue -> assert issue.trigger == "marketing" end)
    end

    test "a typo'd domain is flagged" do
      """
      defmodule TymeslotWeb.Page do
        def users, do: dgettext("dasboard", "Users")
      end
      """
      |> to_source_file("lib/tymeslot_web/page.ex")
      |> run_check(GettextDomainBoundary)
      |> assert_issue(fn issue -> assert issue.trigger == "dasboard" end)
    end
  end

  describe "no false positives" do
    test "a dynamic (non-literal) domain is not flagged" do
      """
      defmodule TymeslotWeb.Page do
        def render(domain), do: dgettext(domain, "Some string")
      end
      """
      |> to_source_file("lib/tymeslot_web/page.ex")
      |> run_check(GettextDomainBoundary)
      |> refute_issues()
    end

    test "the gettext.ex backend file is excluded" do
      """
      defmodule TymeslotWeb.Gettext do
        @moduledoc "gettext(\\"example\\")"
        use Gettext.Backend, otp_app: :tymeslot
      end
      """
      |> to_source_file("lib/tymeslot_web/gettext.ex")
      |> run_check(GettextDomainBoundary)
      |> refute_issues()
    end

    test "test files are excluded" do
      """
      defmodule TymeslotWeb.PageTest do
        def expected, do: gettext("Confirm your booking")
      end
      """
      |> to_source_file("test/tymeslot_web/page_test.exs")
      |> run_check(GettextDomainBoundary)
      |> refute_issues()
    end

    test "a call named gettext_comment is not flagged" do
      # The check matches call names exactly, so a translator-comment macro
      # whose name merely starts with "gettext" must not be mistaken for a
      # bare `gettext/1`.
      """
      defmodule TymeslotWeb.Page do
        def note do
          gettext_comment("Shown above the confirmation button")
          dgettext("booking", "Confirm your booking")
        end
      end
      """
      |> to_source_file("lib/tymeslot_web/page.ex")
      |> run_check(GettextDomainBoundary)
      |> refute_issues()
    end
  end
end
