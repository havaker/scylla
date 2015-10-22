/*
 * Licensed to the Apache Software Foundation (ASF) under one
 * or more contributor license agreements.  See the NOTICE file
 * distributed with this work for additional information
 * regarding copyright ownership.  The ASF licenses this file
 * to you under the Apache License, Version 2.0 (the
 * "License"); you may not use this file except in compliance
 * with the License.  You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

/*
 * Modified by ScyllaDB
 * Copyright 2015 ScyllaDB
 */

/*
 * This file is part of Scylla.
 *
 * Scylla is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Affero General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * Scylla is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with Scylla.  If not, see <http://www.gnu.org/licenses/>.
 */

#include "load_broadcaster.hh"

logging::logger logger("load_broadcaster");

void load_broadcaster::start_broadcasting() {
    _done = make_ready_future<>();

    // send the first broadcast "right away" (i.e., in 2 gossip heartbeats, when we should have someone to talk to);
    // after that send every BROADCAST_INTERVAL.

    _timer.set_callback([this] {
        logger.debug("Disseminating load info ...");
        _done = _db.map_reduce0([](database& db) {
            int64_t res = 0;
            for (auto i : db.get_column_families()) {
                res += i.second->get_stats().live_disk_space_used;
            }
            return res;
        }, 0, std::plus<int64_t>()).then([this](int64_t size) {
            gms::versioned_value::versioned_value_factory value_factory;
            _gossiper.add_local_application_state(gms::application_state::LOAD, value_factory.load(size));
            _timer.arm(BROADCAST_INTERVAL);
        });
    });

    _timer.arm(2 * gms::gossiper::INTERVAL);
}

future<> load_broadcaster::stop_broadcasting() {
    _timer.cancel();
    return std::move(_done);
}
