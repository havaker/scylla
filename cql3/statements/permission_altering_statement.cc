/*
 * Copyright 2016-present ScyllaDB
 *
 * Modified by ScyllaDB
 */

/*
 * SPDX-License-Identifier: (AGPL-3.0-or-later and Apache-2.0)
 */

#include <seastar/core/thread.hh>

#include "auth/service.hh"
#include "permission_altering_statement.hh"
#include "cql3/query_processor.hh"
#include "cql3/query_options.hh"
#include "cql3/role_name.hh"
#include "cql3/selection/selection.hh"
#include "gms/feature_service.hh"

static auth::permission_set filter_applicable_permissions(const auth::permission_set& ps, const auth::resource& r) {
    auto const filtered_permissions = auth::permission_set::from_mask(ps.mask() & r.applicable_permissions().mask());

    if (!filtered_permissions) {
        throw exceptions::invalid_request_exception(
                format("Resource {} does not support any of the requested permissions.", r));
    }

    return filtered_permissions;
}

cql3::statements::permission_altering_statement::permission_altering_statement(
                auth::permission_set permissions, auth::resource resource,
                const role_name& rn)
                : _permissions(filter_applicable_permissions(permissions, resource))
                , _resource(std::move(resource))
                , _role_name(rn.to_string()) {
}

void cql3::statements::permission_altering_statement::validate(query_processor&, const service::client_state&) const {
}

future<> cql3::statements::permission_altering_statement::check_access(query_processor& qp, const service::client_state& state) const {
    state.ensure_not_anonymous();
    maybe_correct_resource(_resource, state);

    return state.ensure_exists(_resource).then([this, &state] {
        // check that the user has AUTHORIZE permission on the resource or its parents, otherwise reject
        // GRANT/REVOKE.
        return state.ensure_has_permission({auth::permission::AUTHORIZE, _resource}).then([this, &state] {
            return do_for_each(_permissions, [this, &state](auth::permission p) {
                // TODO: how about we re-write the access check to check a set
                // right away.
                return state.ensure_has_permission({p, _resource});
            });
        });
    });
}
