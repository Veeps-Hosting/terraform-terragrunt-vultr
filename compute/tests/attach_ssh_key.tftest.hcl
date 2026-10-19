mock_provider "vultr" {
  mock_resource "vultr_instance" {
    defaults = {
      main_ip    = "192.0.2.10"
      v6_main_ip = "2001:db8::10"
    }
  }
  mock_data "vultr_ssh_key" {
    defaults = {
      id = "mock-ssh-key-id"
    }
  }
  mock_data "vultr_startup_script" {
    defaults = {
      id = "mock-script-id"
    }
  }
  mock_data "vultr_firewall_group" {
    defaults = {
      id = "mock-fw-id"
    }
  }
}

variables {
  hostname = "testhost"
  domain   = "syd3-veepshosting.net"
  ssh_key  = "grant"
}

run "default_attaches_ssh_key_and_script" {
  command = plan

  assert {
    condition     = vultr_instance.server.ssh_key_ids == tolist(["mock-ssh-key-id"])
    error_message = "ssh_key_ids must carry the looked-up key by default"
  }

  assert {
    condition     = vultr_instance.server.script_id == "mock-script-id"
    error_message = "script_id must be set by default"
  }
}

run "windows_skips_ssh_key_keeps_script" {
  command = plan

  variables {
    attach_ssh_key = false
    os_id          = "2514"
    startup_script = "openvox_windows2025"
  }

  assert {
    condition     = vultr_instance.server.ssh_key_ids == null
    error_message = "ssh_key_ids must be null when attach_ssh_key is false"
  }

  assert {
    condition     = vultr_instance.server.script_id == "mock-script-id"
    error_message = "script_id must still be set when attach_ssh_key is false"
  }
}

run "adopted_leaf_sends_no_ssh_key" {
  command = plan

  variables {
    adopt_existing = true
  }

  assert {
    condition     = vultr_instance.server.ssh_key_ids == null
    error_message = "adopted leaves must not send ssh_key_ids"
  }
}
