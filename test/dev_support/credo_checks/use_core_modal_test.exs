Code.require_file(
  "dev_support/credo_checks/html_tags.ex",
  Path.join(__DIR__, "../../..")
)

Code.require_file(
  "dev_support/credo_checks/use_core_modal.ex",
  Path.join(__DIR__, "../../..")
)

defmodule CredoChecks.UseCoreModalTest do
  use Credo.Test.Case, async: false

  alias CredoChecks.UseCoreModal

  @moduletag :dev_support

  setup_all do
    Application.ensure_all_started(:credo)
    :ok
  end

  defp check(source) do
    source
    |> to_source_file("lib/tymeslot_web/live/some_live.ex")
    |> run_check(UseCoreModal)
  end

  test "flags a hand-rolled backdrop" do
    ~S'''
    defmodule TymeslotWeb.SomeLive do
      def render(assigns) do
        ~H"""
        <div class="fixed inset-0 z-50 flex items-center justify-center">
        </div>
        """
      end
    end
    '''
    |> check()
    |> assert_issue(fn issue -> assert issue.line_no == 4 end)
  end

  test "flags a backdrop whose attributes the formatter has wrapped" do
    ~S'''
    defmodule TymeslotWeb.SomeLive do
      def render(assigns) do
        ~H"""
        <div
          id="overlay"
          class="fixed inset-0 z-50 flex items-center justify-center bg-black/50"
        >
        </div>
        """
      end
    end
    '''
    |> check()
    |> assert_issue(fn issue -> assert issue.line_no == 4 end)
  end

  test "leaves a fixed element that is not centred alone" do
    ~S'''
    defmodule TymeslotWeb.SomeLive do
      def render(assigns) do
        ~H"""
        <div
          class="fixed inset-0 pointer-events-none"
        >
        </div>
        """
      end
    end
    '''
    |> check()
    |> refute_issues()
  end
end
