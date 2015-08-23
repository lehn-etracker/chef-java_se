# inspiration from https://github.com/agileorbit-cookbooks/java

extend Chef::Mixin::ShellOut

version = node['java_se']['version']
bin_cmds = node['java_se']['bin_cmds']
default = node['java_se']['set_default']
priority = node['java_se']['alternatives_priority']
owner = node['java_se']['owner']
group = node['java_se']['group']
java_home = node['java_se']['java_home']
java_home = '/usr/lib/jvm/java' if java_home.nil? || java_home.empty?

ruby_block 'set-env-java-home' do
  block do
    ENV['JAVA_HOME'] = java_home
  end
  not_if { ENV['JAVA_HOME'] == java_home }
end

directory '/etc/profile.d' do
  mode 00755
end

file '/etc/profile.d/jdk.sh' do
  content "export JAVA_HOME=#{java_home}"
  mode 00755
end

ruby_block 'Set JAVA_HOME in /etc/environment' do
  block do
    file = Chef::Util::FileEdit.new('/etc/environment')
    file.insert_line_if_no_match(/^JAVA_HOME=/, "JAVA_HOME=#{java_home}")
    file.search_file_replace_line(/^JAVA_HOME=/, "JAVA_HOME=#{java_home}")
    file.write_file
  end
  only_if { node['java_se']['set_etc_environment'] }
end

yum_package 'glibc' do
  arch 'i686'
  only_if { platform_family?('rhel', 'fedora') && node['java_se']['arch'] == 'i586' }
end

package 'tar'

app_dir_name = "jdk#{version}"
app_root = java_home.split('/')[0..-2].join('/')
app_dir = "#{app_root}/#{app_dir_name}"

if default && node['java_se']['use_alt_suffix']
  Chef::Log.debug('processing alternate jdk')
  app_dir = "#{app_dir}_alt"
  java_home = "#{java_home}_alt"
end

ruby_block "Adding to #{app_dir}" do
  block do
    require 'fileutils'

    unless ::File.exist?(app_root)
      FileUtils.mkdir app_root, mode: node['java_se']['java_home_mode']
      FileUtils.chown owner, group, app_root
    end

    cmd = shell_out(
      %( tar xvzf "#{node['java_se']['file_cache_path']}" -C "#{Chef::Config[:file_cache_path]}" --no-same-owner)
    )
    unless cmd.exitstatus == 0
      Chef::Application.fatal!("Failed to extract file #{tarball_name}!")
    end

    cmd = shell_out(
      %( mv "#{Chef::Config[:file_cache_path]}/#{app_dir_name}" "#{app_dir}" )
    )
    unless cmd.exitstatus == 0
      Chef::Application.fatal!(
        %( Command \' mv "#{Chef::Config[:file_cache_path]}/#{app_dir_name}" "#{app_dir}" \' failed ))
    end

    # change ownership of extracted files
    FileUtils.chown_R owner, group, app_root
  end
  not_if { ::File.exist?(app_dir) }
end

# set up .jinfo file for update-java-alternatives
java_name =  java_home.split('/')[-1]
jinfo_file = "#{app_root}/.#{java_name}.jinfo"
template "Adding #{jinfo_file} for debian" do
  path jinfo_file
  cookbook 'java_se'
  source 'oracle.jinfo.erb'
  owner owner
  group group
  variables(
    priority: priority,
    bin_cmds: bin_cmds,
    name: java_name,
    app_dir: java_home
  )
  action :create
  only_if { platform_family?('debian') && !::File.exist?(jinfo_file) }
end

# link java_home to app_dir
Chef::Log.debug "java_home is #{java_home} and app_dir is #{app_dir}"
current_link = ::File.symlink?(java_home) ? ::File.readlink(java_home) : nil
ruby_block "Symlink #{app_dir} to #{java_home}" do
  block do
    FileUtils.rm_f java_home
    FileUtils.ln_sf app_dir, java_home
    FileUtils.chown owner, group, java_home
  end
  only_if { current_link != app_dir }
end

# rubocop:disable  Style/Next
ruby_block 'update-alternatives' do
  block do
    alternatives_cmd = node['platform_family'] == 'rhel' ? 'alternatives' : 'update-alternatives'
    bin_cmds.each do |cmd|
      bin_path = "/usr/bin/#{cmd}"
      alt_path = "#{java_home}/bin/#{cmd}"

      unless ::File.exist?(alt_path)
        Chef::Log.info "Skipping setting alternative for #{cmd}. Command #{alt_path} does not exist."
        next
      end

      alternative_exists_same_prio = shell_out(
        "#{alternatives_cmd} --display #{cmd} | grep #{alt_path} | grep 'priority #{priority}$'").exitstatus == 0
      alternative_exists = shell_out("#{alternatives_cmd} --display #{cmd} | grep #{alt_path}").exitstatus == 0
      # remove alternative if priority is changed and install it with new priority
      if alternative_exists && !alternative_exists_same_prio
        Chef::Log.info "Removing alternative for #{cmd} with old priority"
        alternative_exists = false
        unless shell_out("#{alternatives_cmd} --remove #{cmd} #{alt_path}").exitstatus == 0
          fail('remove alternative failed')
        end
      end
      # install the alternative if needed
      unless alternative_exists
        Chef::Log.info "Adding alternative for #{cmd}"
        if node['java_se']['reset_alternatives']
          shell_out("rm /var/lib/alternatives/#{cmd}")
        end
        unless shell_out("#{alternatives_cmd} --install #{bin_path} #{cmd} #{alt_path} #{priority}").exitstatus == 0
          fail("install alternative failed #{alternatives_cmd} --install #{bin_path} #{cmd} #{alt_path} #{priority}")
        end
      end

      # set the alternative if default
      if default
        unless shell_out(
          "#{alternatives_cmd} --display #{cmd} | grep \"link currently points to #{alt_path}\"").exitstatus == 0
          Chef::Log.info "Setting alternative for #{cmd}"
          unless shell_out("#{alternatives_cmd} --set #{cmd} #{alt_path}").exitstatus == 0
            fail('set alternative failed')
          end
        end
      end
    end
  end
  only_if { bin_cmds }
end
# rubocop:enable Style/Next

if default && platform_family?('debian')
  link '/usr/lib/jvm/default-java' do
    to java_home
    not_if { java_home == '/usr/lib/jvm/default-java' }
  end
end
