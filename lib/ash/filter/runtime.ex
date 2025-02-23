defmodule Ash.Filter.Runtime do
  @moduledoc """
  Checks a record to see if it matches a filter statement.

  We can't always tell if a record matches a filter statement, and as such this
  function may return `:unknown`. Additionally, some expressions wouldn't ever
  make sense outside of the context of the data layer, and will always be an
  error. For example, if you used the trigram search features in
  `ash_postgres`. That logic would need to be handwritten in Elixir and would
  need to be a *perfect* copy of the postgres implementation. That isn't a
  realistic goal. This generally should not affect anyone using the standard
  framework features, but if you were to attempt to use this module with a data
  layer like `ash_postgres`, certain expressions will behave unpredictably.
  """

  alias Ash.Query.{BooleanExpression, Call, Not, Ref}

  @doc """
  Removes any records that don't match the filter. Automatically loads
  if necessary. If there are any ambiguous terms in the filter (e.g things
  that could only be determined by data layer), it is assumed that they
  are not matches.
  """
  def filter_matches(api, records, filter, opts \\ [])
  def filter_matches(_api, [], _filter, _opts), do: {:ok, []}

  def filter_matches(_api, records, nil, _opts), do: {:ok, records}

  def filter_matches(api, records, filter, opts) do
    resource =
      case records do
        %resource{} ->
          resource

        [%resource{} | _] ->
          resource
      end

    {refs_to_load, refs} =
      filter
      |> Ash.Filter.list_refs()
      |> Enum.split_with(&(&1.relationship_path == []))

    refs_to_load =
      refs_to_load
      |> Enum.map(fn
        %{attribute: %{name: name}} ->
          name

        %{attribute: name} when is_atom(name) ->
          name

        _ ->
          nil
      end)
      |> Enum.filter(& &1)
      |> Enum.reject(&Ash.Resource.loaded?(records, &1))

    records =
      case refs_to_load do
        [] ->
          records

        refs_to_load ->
          api.load!(records, refs_to_load)
      end

    filter
    |> Ash.Filter.relationship_paths(true)
    |> Enum.reject(&(&1 == []))
    |> Enum.uniq()
    |> Enum.reject(&Ash.Resource.loaded?(records, &1))
    |> Enum.map(&path_to_load(resource, &1, refs))
    |> case do
      [] ->
        Enum.reduce_while(records, {:ok, []}, fn record, {:ok, records} ->
          matches = matches(record, filter, Keyword.put(opts, :parent_loaded?, true))

          case matches do
            {:ok, falsey} when falsey in [false, nil] ->
              {:cont, {:ok, records}}

            {:ok, _} ->
              {:cont, {:ok, [record | records]}}

            {:error, error} ->
              {:halt, {:error, error}}
          end
        end)
        |> case do
          {:ok, records} ->
            {:ok, Enum.reverse(records)}

          other ->
            other
        end

      need_to_load ->
        query =
          resource
          |> Ash.Query.load(need_to_load)
          |> Ash.Query.set_context(%{private: %{internal?: true}})

        case api.load(records, query) do
          {:ok, loaded} ->
            filter_matches(api, loaded, filter, opts)

          other ->
            other
        end
    end
  end

  def load_parent_requirements(api, expression, %resource{} = parent) do
    expression
    |> Ash.Filter.flat_map(fn %Ash.Query.Parent{expr: expr} ->
      Ash.Filter.list_refs(expr)
    end)
    |> Enum.reject(&match?(%{attribute: %Ash.Resource.Attribute{}}, &1))
    |> Enum.uniq()
    |> case do
      [] ->
        {:ok, parent}

      refs ->
        to_load =
          refs
          |> Enum.map(& &1.relationship_path)
          |> Enum.uniq()
          |> Enum.map(&path_to_load(resource, &1, refs))

        query =
          resource
          |> Ash.Query.load(to_load)
          |> Ash.Query.set_context(%{private: %{internal?: true}})

        api.load(parent, query)
    end
  end

  defp matches(%resource{} = record, expression, opts) do
    relationship_paths =
      expression
      |> Ash.Filter.relationship_paths(true)
      |> Enum.uniq()

    relationship_paths
    |> Enum.reject(&Ash.Resource.loaded?(record, &1))
    |> case do
      [] ->
        record
        |> flatten_relationships(relationship_paths)
        |> Enum.reduce_while({:ok, false}, fn scenario, {:ok, false} ->
          case do_match(scenario, expression, opts[:parent]) do
            {:error, error} ->
              {:halt, {:error, error}}

            :unknown ->
              {:halt, {:ok, false}}

            {:ok, val} when val ->
              {:halt, {:ok, true}}

            {:ok, _} ->
              {:cont, {:ok, false}}
          end
        end)

      need_to_load ->
        {:load, Enum.map(need_to_load, &path_to_load(resource, &1, []))}
    end
  end

  defp flatten_relationships(record, relationship_paths) do
    relationship_paths
    |> Enum.reject(&(&1 == []))
    |> Enum.reduce([record], fn [rel | rest], records ->
      Enum.flat_map(records, fn record ->
        case Map.get(record, rel) do
          nil ->
            [record]

          [] ->
            [record]

          value when is_list(value) ->
            flatten_many_to_many(record, rel, value, rest)

          value ->
            flatten_to_one(record, rel, value, rest)
        end
      end)
    end)
  end

  defp flatten_many_to_many(record, rel, values, rest) do
    full_flattened = Enum.map(values, &flatten_relationships(&1, [rest])) |> List.flatten()

    Enum.map(full_flattened, fn value ->
      record
      |> Map.put(rel, value)
      |> Ash.Resource.set_metadata(%{unflattened_rels: %{rel => full_flattened}})
    end)
  end

  defp flatten_to_one(record, rel, value, rest) do
    full_flattened = flatten_relationships(value, [rest])

    Enum.map(full_flattened, fn value ->
      record
      |> Map.put(rel, value)
      |> Ash.Resource.set_metadata(%{unflattened_rels: %{rel => full_flattened}})
    end)
  end

  @doc false
  def load_and_eval(record, expression, parent \\ nil, resource \\ nil, api \\ nil) do
    if api && record do
      {refs_to_load, refs} =
        expression
        |> Ash.Filter.list_refs()
        |> Enum.split_with(&(&1.relationship_path == []))

      refs_to_load =
        refs_to_load
        |> Enum.map(fn
          %{attribute: %{name: name}} ->
            name

          %{attribute: name} when is_atom(name) ->
            name

          _ ->
            nil
        end)
        |> Enum.filter(& &1)
        |> Enum.reject(&Ash.Resource.loaded?(record, &1))

      record =
        case refs_to_load do
          [] ->
            record

          refs ->
            api.load!(record, refs)
        end

      expression
      |> Ash.Filter.relationship_paths(true)
      |> Enum.reject(&(&1 == []))
      |> Enum.uniq()
      |> Enum.reject(&Ash.Resource.loaded?(record, &1))
      |> Enum.map(&path_to_load(resource, &1, refs))
      |> case do
        [] ->
          do_match(record, expression, parent, resource)

        need_to_load ->
          query =
            resource
            |> Ash.Query.load(need_to_load)
            |> Ash.Query.set_context(%{private: %{internal?: true}})

          case api.load(record, query) do
            {:ok, loaded} ->
              do_match(loaded, expression, parent, resource)

            other ->
              other
          end
      end
    else
      do_match(record, expression, parent, resource)
    end
  end

  @doc false
  def do_match(record, expression, parent \\ nil, resource \\ nil) do
    hydrated =
      case record do
        %resource{} ->
          Ash.Filter.hydrate_refs(expression, %{
            resource: resource,
            public?: false
          })

        _ ->
          if resource do
            Ash.Filter.hydrate_refs(expression, %{
              resource: resource,
              public?: false
            })
          else
            {:ok, expression}
          end
      end

    case hydrated do
      {:ok, expression} ->
        case expression do
          %Ash.Filter{expression: expression} ->
            do_match(record, expression, parent, resource)

          %op{__operator__?: true, left: left, right: right} ->
            with {:ok, [left, right]} <-
                   resolve_exprs([left, right], record, parent, resource),
                 {:op, {:ok, %op{} = new_operator}} <-
                   {:op, Ash.Query.Operator.try_cast_with_ref(op, left, right)},
                 {:known, val} <-
                   op.evaluate(new_operator) do
              {:ok, val}
            else
              {:op, {:error, error}} ->
                {:error, error}

              {:op, {:ok, expr}} ->
                do_match(record, expr, parent, resource)

              {:error, error} ->
                {:error, error}

              :unknown ->
                :unknown

              _value ->
                :unknown
            end

          %func{__function__?: true, arguments: arguments} = function ->
            with {:ok, args} <- resolve_exprs(arguments, record, parent, resource),
                 {:args, args} when not is_nil(args) <-
                   {:args, try_cast_arguments(func.args(), args)},
                 {:known, val} <- func.evaluate(%{function | arguments: args}) do
              {:ok, val}
            else
              {:args, nil} ->
                {:error,
                 "Could not cast function arguments for #{func.name()}/#{Enum.count(arguments)}"}

              {:error, error} ->
                {:error, error}

              :unknown ->
                :unknown

              _ ->
                :unknown
            end

          %Not{expression: nil} ->
            {:ok, nil}

          %Not{expression: expression} ->
            case do_match(record, expression, parent, resource) do
              :unknown ->
                :unknown

              {:ok, nil} ->
                {:ok, nil}

              {:ok, match?} ->
                {:ok, !match?}

              {:error, error} ->
                {:error, error}
            end

          %Ash.Query.Exists{} = expr ->
            resolve_expr(expr, record, parent, resource)

          %Ash.Query.Parent{} = expr ->
            resolve_expr(expr, parent, nil, resource)

          %BooleanExpression{op: op, left: left, right: right} ->
            expression_matches(op, left, right, record, parent)

          %Call{} = call ->
            raise "Unresolvable filter component: #{inspect(call)}"

          %Ref{} = ref ->
            resolve_expr(ref, record, parent, resource)

          value when is_list(value) ->
            value
            |> Enum.reduce_while({:ok, []}, fn value, {:ok, list} ->
              case do_match(record, value, parent, resource) do
                {:ok, result} ->
                  {:cont, {:ok, [result | list]}}

                other ->
                  {:halt, other}
              end
            end)
            |> case do
              {:ok, list} ->
                {:ok, Enum.reverse(list)}

              other ->
                other
            end

          other ->
            {:ok, other}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  defp load_unflattened(record, []), do: record
  defp load_unflattened(nil, _), do: nil

  defp load_unflattened(records, path) when is_list(records) do
    Enum.map(records, &load_unflattened(&1, path))
  end

  defp load_unflattened(record, [rel | rest]) do
    Map.put(
      record,
      rel,
      load_unflattened(record.__metadata__[:unflattened_rels][rel], rest)
    )
  end

  defp resolve_exprs(exprs, record, parent, resource) do
    exprs
    |> Enum.reduce_while({:ok, []}, fn expr, {:ok, exprs} ->
      case resolve_expr(expr, record, parent, resource) do
        {:ok, resolved} -> {:cont, {:ok, [resolved | exprs]}}
        {:error, error} -> {:halt, {:error, error}}
        :unknown -> {:halt, :unknown}
      end
    end)
    |> case do
      :unknown -> :unknown
      {:ok, resolved} -> {:ok, Enum.reverse(resolved)}
      {:error, error} -> {:error, error}
    end
  end

  defp resolve_expr({key, value}, record, parent, resource) when is_atom(key) do
    case resolve_expr(value, record, parent, resource) do
      {:ok, resolved} ->
        {:ok, {key, resolved}}

      other ->
        other
    end
  end

  defp resolve_expr(%Ref{} = ref, record, parent, resource) do
    resolve_ref(ref, record, parent, resource)
  end

  defp resolve_expr(
         %BooleanExpression{op: :and, left: left, right: right},
         record,
         parent,
         resource
       ) do
    with {:ok, left_resolved} <- resolve_expr(left, record, parent, resource),
         {:ok, right_resolved} <- resolve_expr(right, record, parent, resource) do
      if is_nil(left_resolved) || is_nil(right_resolved) do
        {:ok, nil}
      else
        {:ok, !!left_resolved and !!right_resolved}
      end
    end
  end

  defp resolve_expr(
         %BooleanExpression{op: :or, left: left, right: right},
         record,
         parent,
         resource
       ) do
    with {:ok, left_resolved} <- resolve_expr(left, record, parent, resource),
         {:ok, right_resolved} <- resolve_expr(right, record, parent, resource) do
      if is_nil(left_resolved) || is_nil(right_resolved) do
        {:ok, nil}
      else
        {:ok, !!left_resolved or !!right_resolved}
      end
    end
  end

  defp resolve_expr(%Not{expression: expression}, record, parent, resource) do
    case resolve_expr(expression, record, parent, resource) do
      {:ok, resolved} -> {:ok, !resolved}
      other -> other
    end
  end

  defp resolve_expr(%Ash.Query.Parent{expr: expr}, _, parent, resource) do
    resolve_expr(expr, parent, nil, resource)
  end

  defp resolve_expr(%Ash.Query.Exists{}, nil, _parent, _resource), do: :unknown

  defp resolve_expr(
         %Ash.Query.Exists{at_path: [], path: path, expr: expr},
         record,
         _parent,
         resource
       ) do
    record
    |> flatten_relationships([path])
    |> load_unflattened(path)
    |> get_related(path)
    |> case do
      :unknown ->
        :unknown

      related ->
        related
        |> List.wrap()
        |> Enum.reduce_while({:ok, false}, fn related, {:ok, false} ->
          case resolve_expr(expr, related, record, resource) do
            {:ok, falsy} when falsy in [nil, false] ->
              {:cont, {:ok, false}}

            {:ok, _} ->
              {:halt, {:ok, true}}

            other ->
              {:halt, other}
          end
        end)
    end
  end

  defp resolve_expr(%Ash.Query.Exists{at_path: at_path} = exists, record, parent, resource) do
    record
    |> flatten_relationships([at_path])
    |> get_related(at_path)
    |> case do
      :unknown ->
        :unknown

      related ->
        related
        |> Enum.reduce_while({:ok, false}, fn related, {:ok, false} ->
          case resolve_expr(%{exists | at_path: []}, related, parent, resource) do
            {:ok, true} ->
              {:halt, {:ok, true}}

            {:ok, _} ->
              {:cont, {:ok, false}}

            other ->
              {:halt, other}
          end
        end)
    end
  end

  defp resolve_expr(%mod{__predicate__?: _, left: left, right: right}, record, parent, resource) do
    with {:ok, [left, right]} <- resolve_exprs([left, right], record, parent, resource),
         {:op, {:ok, %mod{} = new_pred}} <-
           {:op, Ash.Query.Operator.try_cast_with_ref(mod, left, right)},
         {:known, val} <- mod.evaluate(new_pred) do
      {:ok, val}
    else
      {:op, {:error, error}} ->
        {:error, error}

      {:op, {:ok, expr}} ->
        resolve_expr(expr, record, parent, resource)

      {:error, error} ->
        {:error, error}

      :unknown ->
        :unknown

      _ ->
        {:ok, nil}
    end
  end

  defp resolve_expr(%mod{__predicate__?: _, arguments: args} = pred, record, parent, resource) do
    with {:ok, args} <- resolve_exprs(args, record, parent, resource),
         {:args, args} when not is_nil(args) <-
           {:args, try_cast_arguments(mod.args(), args)},
         {:known, val} <- mod.evaluate(%{pred | arguments: args}) do
      {:ok, val}
    else
      {:args, nil} ->
        {:error, "Could not cast function arguments for #{mod.name()}/#{Enum.count(args)}"}

      {:error, error} ->
        {:error, error}

      :unknown ->
        :unknown

      _ ->
        {:ok, nil}
    end
  end

  defp resolve_expr(list, record, parent, resource) when is_list(list) do
    list
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case resolve_expr(item, record, parent, resource) do
        {:ok, result} ->
          {:cont, {:ok, [result | acc]}}

        :unknown ->
          {:halt, :unknown}

        {:error, error} ->
          {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      other -> other
    end
  end

  defp resolve_expr(other, _, _, _), do: {:ok, other}

  defp try_cast_arguments(:var_args, args) do
    Enum.map(args, fn _ -> :any end)
  end

  defp try_cast_arguments(configured_args, args) do
    given_arg_count = Enum.count(args)

    configured_args
    |> Enum.filter(fn args ->
      Enum.count(args) == given_arg_count
    end)
    |> Enum.find_value(&Ash.Query.Function.try_cast_arguments(&1, args))
  end

  defp resolve_ref(
         %Ash.Query.Ref{
           relationship_path: relationship_path,
           attribute: %Ash.Query.Calculation{
             module: module,
             opts: opts,
             context: context
           }
         },
         record,
         parent,
         resource
       ) do
    if function_exported?(module, :expression, 2) do
      expression = module.expression(opts, context)

      hydrated =
        case record do
          %resource{} ->
            Ash.Filter.hydrate_refs(expression, %{
              resource: resource,
              public?: false
            })

          _ ->
            if resource do
              Ash.Filter.hydrate_refs(expression, %{
                resource: resource,
                public?: false
              })
            else
              {:ok, expression}
            end
        end

      with {:ok, hydrated} <- hydrated do
        hydrated
        |> Ash.Filter.prefix_refs(relationship_path)
        |> resolve_expr(record, parent, resource)
      end
    else
      # We need to rewrite this
      # As it stands now, it will evaluate the calculation
      # once per expanded result. I'm not sure what that will
      # look like though.
      case module.calculate([record], opts, context) do
        [result] ->
          {:ok, result}

        {:ok, [result]} ->
          {:ok, result}

        _ ->
          {:ok, nil}
      end
    end
  end

  defp resolve_ref(%Ash.Query.Ref{attribute: attribute}, nil, _, _resource),
    do: :unknown |> or_default(attribute)

  defp resolve_ref(_ref, nil, _, _resource) do
    :unknown
  end

  defp resolve_ref(
         %Ref{attribute: attribute, relationship_path: path},
         record,
         _parent,
         _resource
       ) do
    name =
      case attribute do
        %{name: name} -> name
        name -> name
      end

    record
    |> get_related(path)
    |> case do
      :unknown ->
        :unknown

      [] ->
        {:ok, nil}

      [record] ->
        {:ok, Map.get(record, name)}

      [%struct{} = record] ->
        if Spark.Dsl.is?(struct, Ash.Resource) do
          if Ash.Resource.Info.attribute(struct, name) do
            if Ash.Resource.selected?(record, name) do
              {:ok, Map.get(record, name)}
            else
              :unknown
            end
          else
            if Ash.Resource.loaded?(record, name) do
              {:ok, Map.get(record, name)}
            else
              :unknown
            end
          end
        else
          {:ok, Map.get(record, name)}
        end

      %struct{} = record ->
        if Spark.Dsl.is?(struct, Ash.Resource) do
          if Ash.Resource.Info.attribute(struct, name) do
            if Ash.Resource.selected?(record, name) do
              {:ok, Map.get(record, name)}
            else
              :unknown
            end
          else
            if Ash.Resource.loaded?(record, name) do
              {:ok, Map.get(record, name)}
            else
              :unknown
            end
          end
        else
          {:ok, Map.get(record, name)}
        end

      record ->
        {:ok, Map.get(record, name)}
    end
    |> or_default(attribute)
  end

  defp resolve_ref(_value, _record, _, _), do: :unknown

  defp or_default(:unknown, %Ash.Resource.Aggregate{default: default}) when not is_nil(default) do
    if is_function(default) do
      {:ok, default.()}
    else
      {:ok, default}
    end
  end

  defp or_default({:ok, nil}, %Ash.Resource.Aggregate{default: default})
       when not is_nil(default) do
    if is_function(default) do
      {:ok, default.()}
    else
      {:ok, default}
    end
  end

  defp or_default(other, _), do: other

  defp path_to_load(resource, [first], refs) do
    to_load =
      refs
      |> Enum.filter(&(&1.relationship_path == [first]))
      |> Enum.map(fn
        %{attribute: %Ash.Resource.Calculation{load: nil} = calc} ->
          {calc.name, calc}

        %{attribute: %{name: name}} ->
          name
      end)

    query =
      resource
      |> Ash.Resource.Info.related(first)
      |> Ash.Query.set_context(%{private: %{internal?: true}})
      |> Ash.Query.load(to_load)

    {first, query}
  end

  defp path_to_load(resource, [first | rest], refs) do
    related = Ash.Resource.Info.related(resource, first)

    to_load =
      refs
      |> Enum.filter(&(&1.relationship_path == [first]))
      |> Enum.map(fn
        %{attribute: %Ash.Resource.Calculation{load: nil} = calc} ->
          {calc.name, calc}

        %{attribute: %{name: name}} ->
          name
      end)

    further_refs =
      refs
      |> Enum.filter(fn ref ->
        ref.relationship_path
        |> Enum.at(0)
        |> Kernel.==(first)
      end)
      |> Enum.map(fn ref ->
        %{ref | relationship_path: Enum.drop(ref.relationship_path, 1)}
      end)

    {first, [path_to_load(related, rest, further_refs)] ++ to_load}
  end

  defp expression_matches(:and, left, right, record, parent) do
    case do_match(record, left, parent) do
      {:ok, false} ->
        {:ok, false}

      {:ok, nil} ->
        {:ok, nil}

      {:ok, true} ->
        case do_match(record, right, parent) do
          {:ok, false} ->
            {:ok, false}

          {:ok, nil} ->
            {:ok, nil}

          {:ok, _} ->
            {:ok, true}

          :unknown ->
            :unknown
        end

      :unknown ->
        :unknown
    end
  end

  defp expression_matches(:or, left, right, record, parent) do
    case do_match(record, left, parent) do
      {:ok, falsy} when falsy in [nil, false] ->
        case do_match(record, right, parent) do
          {:ok, falsy} when falsy in [nil, false] ->
            {:ok, false}

          {:ok, _} ->
            {:ok, true}

          :unknown ->
            :unknown
        end

      {:ok, _} ->
        {:ok, true}

      :unknown ->
        :unknown
    end
  end

  @doc false
  def get_related(nil, _), do: []

  def get_related(%Ash.NotLoaded{}, []) do
    :unknown
  end

  def get_related(record, []) do
    record
  end

  def get_related(records, paths) when is_list(records) do
    records
    |> Enum.reduce_while([], fn
      :unknown, _records ->
        {:halt, :unknown}

      record, records ->
        case get_related(record, paths) do
          :unknown ->
            {:halt, :unknown}

          related ->
            {:cont, [related | records]}
        end
    end)
    |> case do
      :unknown ->
        :unknown

      records ->
        records
        |> List.flatten()
        |> Enum.reverse()
    end
  end

  def get_related(record, [key | rest]) do
    case Map.get(record, key) do
      nil ->
        []

      value ->
        case get_related(value, rest) do
          :unknown ->
            :unknown

          related ->
            List.wrap(related)
        end
    end
  end
end
