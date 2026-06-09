defmodule Tymeslot.Infrastructure.CrashReporterTest do
  @moduledoc false

  use ExUnit.Case, async: false

  @moduletag :infrastructure

  alias Tymeslot.Infrastructure.CrashReporter

  describe "reportable?/2" do
    test "exceptions not in the ignore list are reportable" do
      assert CrashReporter.reportable?(:error, %RuntimeError{message: "boom"})
    end

    test "ignored (4xx) exceptions are not reportable" do
      refute CrashReporter.reportable?(:error, %Ecto.NoResultsError{message: "none"})
    end

    test "normal exits are not reportable" do
      refute CrashReporter.reportable?(:exit, :normal)
      refute CrashReporter.reportable?(:exit, :shutdown)
      refute CrashReporter.reportable?(:exit, {:shutdown, :boom})
    end

    test "abnormal exits are reportable" do
      assert CrashReporter.reportable?(:exit, :boom)
    end

    test "throws are reportable" do
      assert CrashReporter.reportable?(:throw, :some_value)
    end
  end
end
