/*
 * Modified by ScyllaDB
 * Copyright (C) 2017-present ScyllaDB
 */

/*
 * SPDX-License-Identifier: (AGPL-3.0-or-later and Apache-2.0)
 */
#include <unordered_map>
#include <boost/range/adaptor/map.hpp>
#include <boost/range/adaptor/sliced.hpp>

#include "replica/database.hh"
#include "cql3/CqlParser.hpp"
#include "cql3/util.hh"
#include "cql_type_parser.hh"
#include "types.hh"
#include "data_dictionary/user_types_metadata.hh"

static ::shared_ptr<cql3::cql3_type::raw> parse_raw(const sstring& str) {
    return cql3::util::do_with_parser(str,
        [] (cql3_parser::CqlParser& parser) {
            return parser.comparator_type(true);
        });
}

data_type db::cql_type_parser::parse(const sstring& keyspace, const sstring& str, const data_dictionary::user_types_storage& uts) {
    static const thread_local std::unordered_map<sstring, cql3::cql3_type> native_types = []{
        std::unordered_map<sstring, cql3::cql3_type> res;
        for (auto& nt : cql3::cql3_type::values()) {
            res.emplace(nt.to_string(), nt);
        }
        return res;
    }();

    auto i = native_types.find(str);
    if (i != native_types.end()) {
        return i->second.get_type();
    }

    auto raw = parse_raw(str);
    return raw->prepare_internal(keyspace, uts.get(keyspace)).get_type();
}

class db::cql_type_parser::raw_builder::impl {
public:
    impl(replica::keyspace_metadata &ks)
        : _ks(ks)
    {}

//    static shared_ptr<user_type_impl> get_instance(sstring keyspace, bytes name, std::vector<bytes> field_names, std::vector<data_type> field_types, bool is_multi_cell) {

    struct entry {
        sstring name;
        std::vector<sstring> field_names;
        std::vector<::shared_ptr<cql3::cql3_type::raw>> field_types;

        user_type prepare(const sstring& keyspace, replica::user_types_metadata& user_types) const {
            std::vector<data_type> fields;
            fields.reserve(field_types.size());
            std::transform(field_types.begin(), field_types.end(), std::back_inserter(fields), [&](auto& r) {
                return r->prepare_internal(keyspace, user_types).get_type();
            });
            std::vector<bytes> names;
            names.reserve(field_names.size());
            std::transform(field_names.begin(), field_names.end(), std::back_inserter(names), [](const sstring& s) {
                return to_bytes(s);
            });

            return user_type_impl::get_instance(keyspace, to_bytes(name), std::move(names), std::move(fields), true);
        }

    };

    void add(sstring name, std::vector<sstring> field_names, std::vector<sstring> field_types) {
        entry e{ std::move(name), std::move(field_names) };
        for (auto& t : field_types) {
            e.field_types.emplace_back(parse_raw(t));
        }
        _definitions.emplace_back(std::move(e));
    }

    // See cassandra Types.java
    std::vector<user_type> build() {
        if (_definitions.empty()) {
            return {};
        }

        /*
         * build a DAG of UDT dependencies
         */
        std::unordered_multimap<entry *, entry *> adjacency;
        for (auto& e1 : _definitions) {
            for (auto& e2 : _definitions) {
                if (&e1 != &e2 && std::any_of(e1.field_types.begin(), e1.field_types.end(), [&e2](auto& t) { return t->references_user_type(e2.name); })) {
                    adjacency.emplace(&e2, &e1);
                }
            }
        }
        /*
         * resolve dependencies in topological order, using Kahn's algorithm
         */
        std::unordered_map<entry *, int32_t> vertices; // map values are numbers of referenced types
        for (auto&p : adjacency) {
            vertices[p.second]++;
        }

        std::deque<entry *> resolvable_types;
        for (auto& e : _definitions) {
            if (!vertices.contains(&e)) {
                resolvable_types.emplace_back(&e);
            }
        }

        // Create a copy of the existing types, so that we don't
        // modify the one in the keyspace. It is up to the caller to
        // do that.
        replica::user_types_metadata types = _ks.user_types();

        const auto &ks_name = _ks.name();
        std::vector<user_type> created;

        while (!resolvable_types.empty()) {
            auto* e =  resolvable_types.front();
            auto r = adjacency.equal_range(e);

            while (r.first != r.second) {
                auto* d = r.first->second;
                if (--vertices[d] == 0) {
                    resolvable_types.push_back(d);
                }
                ++r.first;
            }

            created.push_back(e->prepare(ks_name, types));
            types.add_type(created.back());
            resolvable_types.pop_front();
        }

        if (created.size() != _definitions.size()) {
            throw exceptions::configuration_exception(format("Cannot resolve UDTs for keyspace {}: some types are missing", ks_name));
        }

        return created;
    }
private:
    data_dictionary::keyspace_metadata& _ks;
    std::vector<entry> _definitions;
};

db::cql_type_parser::raw_builder::raw_builder(data_dictionary::keyspace_metadata &ks)
    : _impl(std::make_unique<impl>(ks))
{}

db::cql_type_parser::raw_builder::~raw_builder()
{}

void db::cql_type_parser::raw_builder::add(sstring name, std::vector<sstring> field_names, std::vector<sstring> field_types) {
    _impl->add(std::move(name), std::move(field_names), std::move(field_types));
}

std::vector<user_type> db::cql_type_parser::raw_builder::build() {
    return _impl->build();
}
