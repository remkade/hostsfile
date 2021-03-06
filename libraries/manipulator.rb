#
# Author:: Seth Vargo <sethvargo@gmail.com>
# Cookbook:: hostsfile
# Library:: manipulator
#
# Copyright 2012, Seth Vargo, CustomInk, LCC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require_relative 'entry'

require 'chef/application'
require 'digest/sha2'

class Manipulator
  attr_reader :node

  # Create a new Manipulator object (aka an /etc/hosts manipulator). If a
  # hostsfile is not found, a Chef::Application.fatal is risen, causing
  # the process to terminate on the node and the converge will fail.
  #
  # @param [Chef::node] node
  #   the current Chef node
  # @return [Manipulator]
  #   a class designed to manipulate the node's /etc/hosts file
  def initialize(node)
    @node = node.to_hash

    # Fail if no hostsfile is found
    Chef::Application.fatal! "No hostsfile exists at '#{hostsfile_path}'!" unless ::File.exists?(hostsfile_path)
    contents = ::File.readlines(hostsfile_path)

    @entries = contents.collect do |line|
      Entry.parse(line) unless line.strip.nil? || line.strip.empty?
    end.compact
  end

  # Return a list of all IP Addresses for this hostsfile.
  #
  # @return [Array<IPAddr>]
  #   the list of IP Addresses
  def ip_addresses
    @entries.collect do |entry|
      entry.ip_address
    end.compact || []
  end

  # Add a new record to the hostsfile.
  #
  # @param [Hash] options
  #   a list of options to create the entry with
  # @option options [String] :ip_address
  #   the IP Address for this entry
  # @option options [String] :hostname
  #   the hostname for this entry
  # @option options [String, Array<String>] :aliases
  #   a alias or array of aliases for this entry
  # @option options[String] :comment
  #   an optional comment for this entry
  # @option options [Fixnum] :priority
  #   the relative priority of this entry (compared to others)
  def add(options = {})
    @entries << Entry.new(
      :ip_address   => options[:ip_address],
      :hostname     => options[:hostname],
      :aliases      => options[:aliases],
      :comment      => options[:comment],
      :priority     => options[:priority]
    )
  end

  # Update an existing entry. This method will do nothing if the entry
  # does not exist.
  #
  # @param (see #add)
  def update(options = {})
    if entry = find_entry_by_ip_address(options[:ip_address])
      entry.hostname  = options[:hostname]
      entry.aliases   = options[:aliases]
      entry.comment   = options[:comment]
      entry.priority  = options[:priority]
    end
  end

  # Append content to an existing entry. This method will add a new entry
  # if one does not already exist.
  #
  # @param (see #add)
  def append(options = {})
    if entry = find_entry_by_ip_address(options[:ip_address])
      entry.aliases = [ entry.aliases, options[:hostname], options[:aliases] ].flatten.compact.uniq
      entry.comment = [ entry.comment, options[:comment] ].compact.join(', ') unless entry.comment && entry.comment.include?(options[:comment])
    else
      add(options)
    end
  end

  # Remove an entry by it's IP Address
  #
  # @param [String] ip_address
  #   the IP Address of the entry to remove
  def remove(ip_address)
    if entry = find_entry_by_ip_address(ip_address)
      @entries.delete(entry)
    end
  end

  # Safe save the entry file.
  # @see #save!
  #
  # @return [Boolean]
  #   true if the record was successfully saved, false otherwise
  def save
    save!
    true
  rescue Exception
    false
  end

  # Save the new hostsfile to the target machine. This method will only write the
  # hostsfile if the current version has changed. In other words, it is convergent.
  def save!
    entries = []
    entries << "#"
    entries << "# This file is managed by Chef, using the hostsfile cookbook."
    entries << "# Editing this file by hand is highly discouraged!"
    entries << "#"
    entries << "# Comments containing an @ sign should not be modified or else"
    entries << "# hostsfile will be unable to guarantee relative priority in"
    entries << "# future Chef runs!"
    entries << "#"
    entries << "# Last updated: #{::Time.now}"
    entries << "#"
    entries << ""
    entries += unique_entries.map(&:to_line)
    entries << ""

    contents = entries.join("\n")
    contents_sha = Digest::SHA512.hexdigest(contents)

    # Only write out the file if the contents have changed...
    if contents_sha != current_sha
      ::File.open(hostsfile_path, 'w') do |f|
        f.write(contents)
      end
    end
  end

  # Find an entry by the given IP Address.
  #
  # @param [String] ip_address
  #   the IP Address of the entry to detect
  # @return [Entry, nil]
  #   the corresponding entry object, or nil if it does not exist
  def find_entry_by_ip_address(ip_address)
    @entries.detect do |entry|
      !entry.ip_address.nil? && entry.ip_address == ip_address
    end
  end

  private

    # The path to the current hostsfile.
    #
    # @return [String]
    #   the full path to the hostsfile, depending on the operating system
    def hostsfile_path
      @hostsfile_path ||= case node['platform_family']
        when 'windows'
          "#{node['kernel']['os_info']['system_directory']}\\drivers\\etc\\hosts"
        else
          # debian, rhel, fedora, suse, gentoo, slackware, arch, mac_os_x, windows
          '/etc/hosts'
        end
    end

    # The current sha of the system hostsfile.
    #
    # @return [String]
    #   the sha of the current hostsfile
    def current_sha
      @current_sha ||= Digest::SHA512.hexdigest(File.read(hostsfile_path))
    end

    # This is a crazy way of ensuring unique objects in an array using a Hash.
    #
    # @return [Array]
    #   the sorted list of entires that are unique
    def unique_entries
      remove_existing_hostnames

      entries = Hash[*@entries.map{ |entry| [entry.ip_address, entry] }.flatten].values
      entries.sort_by { |e| [-e.priority.to_i, e.hostname.to_s] }
    end

    # This method ensures that hostnames/aliases and only used once. It
    # doesn't make sense to allow multiple IPs to have the same hostname
    # or aliases. This method removes all occurrences of the existing
    # hostname/aliases from existing records.
    #
    # This method also intelligently removes any entries that should no
    # longer exist.
    def remove_existing_hostnames
      new_entry = @entries.pop
      changed_hostnames = [ new_entry.hostname, new_entry.aliases ].flatten.uniq

      @entries = @entries.collect do |entry|
        entry.hostname = nil if changed_hostnames.include?(entry.hostname)
        entry.aliases = entry.aliases - changed_hostnames

        if entry.hostname.nil?
          if entry.aliases.empty?
            nil
          else
            entry.hostname = entry.aliases.shift
            entry
          end
        else
          entry
        end
      end.compact

      @entries << new_entry
    end
end
