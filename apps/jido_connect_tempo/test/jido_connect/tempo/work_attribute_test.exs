defmodule Jido.Connect.Tempo.WorkAttributeTest do
  use ExUnit.Case, async: true

  alias Jido.Connect.Tempo.{Fixture, WorkAttribute, Worklog}

  # Recorded on 2026-11-03 in two work-attribute windows of the test site.
  # `work_attributes_optional` holds the site's seven attributes with the
  # four test attributes optional, `work_attributes_required` the same with
  # them required; the three attributes outside the test data were
  # neutralized at record time to `_Other1_` to `_Other3_` with their
  # recorded type INPUT_FIELD and required false. Tempo assigns new stored
  # values each time the window creates `_JclPhase_`, so the two pages differ
  # in them. `work_attribute_values` holds the five worklogs of the test user
  # on October 1, 2026, read in the window of the required page; the seeded
  # worklog 79097 carries a value for each test attribute.
  @page "work_attributes_optional"
  @required "work_attributes_required"

  describe "normalize/1" do
    test "keeps key, name, type, required and self of every recorded attribute" do
      attributes = normalized(@page)

      assert Enum.map(attributes, &{&1.key, &1.type, &1.required}) == [
               {"_Other1_", "INPUT_FIELD", false},
               {"_Other2_", "INPUT_FIELD", false},
               {"_Other3_", "INPUT_FIELD", false},
               {"_JclPhase_", "STATIC_LIST", false},
               {"_JclBillable_", "CHECKBOX", false},
               {"_JclHours_", "INPUT_NUMERIC", false},
               {"_JclAccount_", "ACCOUNT", false}
             ]

      assert %WorkAttribute{
               name: "JCL live: account",
               self: "https://api.tempo.io/4/work-attributes/_JclAccount_",
               values: nil
             } = List.last(attributes)
    end

    test "the required page keeps required true for the test attributes only" do
      assert Enum.map(normalized(@required), &{&1.key, &1.required}) == [
               {"_Other1_", false},
               {"_Other2_", false},
               {"_Other3_", false},
               {"_JclPhase_", true},
               {"_JclBillable_", true},
               {"_JclHours_", true},
               {"_JclAccount_", true}
             ]
    end

    test "a static list keeps each stored value with its label, in Tempo's order" do
      phase = recorded_attribute(@page, "_JclPhase_")
      assert {:ok, %WorkAttribute{values: values}} = WorkAttribute.normalize(phase)

      assert values == [
               %{value: "d53fa1d2-c412-44b1-9fc8-ef3f259c4a39", label: "analysis"},
               %{value: "8893d8e8-96df-40d2-b019-6dfaceaefd63", label: "build"},
               %{value: "7ac36b2d-99c7-46ae-95c0-d2319bf44800", label: "review"}
             ]
    end

    # Derived: the test site's labels are distinct and unchanged. Two stored
    # values with the same label stay two values; a renamed label changes
    # only the label of its stored value.
    test "stored values stay distinct when labels are identical or renamed" do
      phase = recorded_attribute(@page, "_JclPhase_")
      [analysis, build, review] = phase["values"]

      identical = put_in(phase, ["names", review], "build")
      renamed = put_in(phase, ["names", build], "implementation")

      assert {:ok, %{values: values}} = WorkAttribute.normalize(identical)
      assert Enum.map(values, & &1.value) == [analysis, build, review]
      assert Enum.map(values, & &1.label) == ["analysis", "build", "build"]

      assert {:ok, %{values: values}} = WorkAttribute.normalize(renamed)
      assert Enum.find(values, &(&1.value == build)).label == "implementation"
    end

    # Derived: the recorded static list without its choice list, with an
    # empty one, and without labels.
    test "a missing choice list stays nil, an empty one stays empty" do
      phase = recorded_attribute(@page, "_JclPhase_")

      assert {:ok, %{values: nil}} = WorkAttribute.normalize(Map.delete(phase, "values"))
      assert {:ok, %{values: nil}} = WorkAttribute.normalize(Map.put(phase, "values", nil))
      assert {:ok, %{values: []}} = WorkAttribute.normalize(Map.put(phase, "values", []))

      assert {:ok, %{values: [%{label: nil} | _rest]}} =
               WorkAttribute.normalize(Map.delete(phase, "names"))
    end

    test "keys and types stay strings and create no atom" do
      novel = %{
        recorded_attribute(@page, "_JclHours_")
        | "key" => "_JclNeverSeenKey273_",
          "type" => "NEVER_SEEN_TYPE_273"
      }

      assert {:ok, %WorkAttribute{key: "_JclNeverSeenKey273_", type: "NEVER_SEEN_TYPE_273"}} =
               WorkAttribute.normalize(novel)

      for text <- ["_JclNeverSeenKey273_", "NEVER_SEEN_TYPE_273"] do
        assert_raise ArgumentError, fn -> String.to_existing_atom(text) end
      end
    end

    test "a missing or malformed field returns its Tempo name" do
      phase = recorded_attribute(@page, "_JclPhase_")

      for {change, field} <- [
            {&Map.delete(&1, "key"), "key"},
            {&Map.put(&1, "key", ""), "key"},
            {&Map.delete(&1, "name"), "name"},
            {&Map.delete(&1, "type"), "type"},
            {&Map.delete(&1, "required"), "required"},
            {&Map.put(&1, "required", "false"), "required"},
            {&Map.put(&1, "self", 5), "self"},
            {&Map.put(&1, "values", "build"), "values"},
            {&Map.put(&1, "values", [5]), "values"},
            {&Map.put(&1, "names", ["build"]), "names"},
            {&put_in(&1, ["names", hd(&1["values"])], 5), "names"}
          ] do
        assert WorkAttribute.normalize(change.(phase)) == {:error, field}
      end

      assert WorkAttribute.normalize("attribute") == {:error, "attribute"}
    end
  end

  describe "value representation" do
    # One recorded value per type on the seeded worklog 79097. Tempo stores
    # every value as a string.
    test "the recorded worklog shows the value each supported type stores" do
      values = recorded_values()
      phase = Enum.find(normalized(@required), &(&1.key == "_JclPhase_"))

      # STATIC_LIST stores one of the attribute's stored values, not its label.
      assert %{value: stored, label: "build"} =
               Enum.find(phase.values, &(&1.value == values["_JclPhase_"]))

      refute stored == "build"

      # CHECKBOX and INPUT_NUMERIC store strings.
      assert values["_JclBillable_"] == "true"
      assert values["_JclHours_"] == "1.5"

      # ACCOUNT stores the account key, not its name or numeric ID.
      account = Fixture.recorded!("accounts_for_project.2")["body"]
      assert values["_JclAccount_"] == account["key"]
      refute values["_JclAccount_"] in [account["name"], Integer.to_string(account["id"])]
    end

    # The test site has no INPUT_FIELD value of the test user; the type comes
    # from the recorded page, the free text it stores is not recorded.
    test "an input field is a supported type" do
      assert {:ok, %{type: "INPUT_FIELD"} = attribute} =
               WorkAttribute.normalize(recorded_attribute(@page, "_Other1_"))

      assert WorkAttribute.supported?(attribute)
    end
  end

  describe "incomplete/1" do
    test "a supported type with its contract is complete, required or not" do
      for attribute <- normalized(@page), required <- [true, false] do
        assert WorkAttribute.incomplete(%{attribute | required: required}) == nil
      end
    end

    # Derived: the recorded attribute with another type.
    test "an unknown required type is incomplete, an unknown optional one is not" do
      hours = normalized_attribute("_JclHours_")

      for type <- ["DYNAMIC_DROPDOWN", "account", ""] do
        refute WorkAttribute.supported?(%{hours | type: type})

        assert WorkAttribute.incomplete(%{hours | type: type, required: true}) ==
                 :unsupported_type

        assert WorkAttribute.incomplete(%{hours | type: type, required: false}) == nil
      end

      assert WorkAttribute.supported_types() ==
               ["ACCOUNT", "CHECKBOX", "INPUT_FIELD", "INPUT_NUMERIC", "STATIC_LIST"]
    end

    test "a required static list without a choice list is incomplete; an empty list is known" do
      phase = normalized_attribute("_JclPhase_")

      assert WorkAttribute.incomplete(%{phase | values: nil, required: true}) == :missing_choices
      assert WorkAttribute.incomplete(%{phase | values: nil, required: false}) == nil
      assert WorkAttribute.incomplete(%{phase | values: [], required: true}) == nil
    end
  end

  test "to_map/1 returns the fields as a plain map" do
    assert WorkAttribute.to_map(normalized_attribute("_JclPhase_")) == %{
             key: "_JclPhase_",
             name: "JCL live: phase",
             type: "STATIC_LIST",
             required: false,
             self: "https://api.tempo.io/4/work-attributes/_JclPhase_",
             values: [
               %{value: "d53fa1d2-c412-44b1-9fc8-ef3f259c4a39", label: "analysis"},
               %{value: "8893d8e8-96df-40d2-b019-6dfaceaefd63", label: "build"},
               %{value: "7ac36b2d-99c7-46ae-95c0-d2319bf44800", label: "review"}
             ]
           }
  end

  defp normalized(name) do
    for attribute <- Fixture.recorded!(name)["body"]["results"] do
      {:ok, attribute} = WorkAttribute.normalize(attribute)
      attribute
    end
  end

  defp normalized_attribute(key), do: Enum.find(normalized(@page), &(&1.key == key))

  defp recorded_attribute(name, key),
    do: Enum.find(Fixture.recorded!(name)["body"]["results"], &(&1["key"] == key))

  defp recorded_values do
    worklog =
      Enum.find(
        Fixture.recorded!("work_attribute_values")["body"]["results"],
        &(&1["tempoWorklogId"] == 79_097)
      )

    {:ok, %Worklog{work_attributes: values}} = Worklog.normalize(worklog)
    Map.new(values, &{&1.key, &1.value})
  end
end
