{% macro generate_schema_name(custom_schema_name, node) -%}

    {%- if custom_schema_name is none -%}
        {%- set schema_name = 'staging' -%}
    {%- else -%}
        {%- set schema_name = custom_schema_name | trim -%}
    {%- endif -%}

    {%- if target.name == 'dev' -%}
        {{ target.schema }}_{{ schema_name }}

    {%- elif target.name == 'prod' -%}
        {{ schema_name }}

    {%- else -%}
        {{ exceptions.raise_compiler_error(
            'Unknown dbt target: ' ~ target.name
        ) }}
    {%- endif -%}

{%- endmacro %}