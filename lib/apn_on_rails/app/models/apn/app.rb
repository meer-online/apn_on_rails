class APN::App < APN::Base

  has_many :groups, :class_name => 'APN::Group', :dependent => :destroy
  has_many :devices, :class_name => 'APN::Device', :dependent => :destroy
  has_many :notifications, :through => :devices, :dependent => :destroy
  has_many :unsent_notifications, :through => :devices
  has_many :group_notifications, :through => :groups
  has_many :unsent_group_notifications, :through => :groups

  def cert
    (RAILS_ENV == 'production' ? apn_prod_cert : apn_dev_cert)
  end

  # Opens a connection to the Apple APN server and attempts to batch deliver
  # an Array of group notifications.
  #
  #
  # As each APN::GroupNotification is sent the <tt>sent_at</tt> column will be timestamped,
  # so as to not be sent again.
  #
  def send_notifications
    if self.cert.nil?
      raise APN::Errors::MissingCertificateError.new
      return
    end
    APN::App.send_notifications_for_cert(self.cert, self.id)
  end

  def self.send_notifications
    apps = APN::App.all
    apps.each do |app|
      app.send_notifications
    end
    if !configatron.apn.cert.blank?
      global_cert = File.read(configatron.apn.cert)
      send_notifications_for_cert(global_cert, nil)
    end
  end

  # def self.send_notifications_for_cert(the_cert, app_id)
  #   # unless self.unsent_notifications.nil? || self.unsent_notifications.empty?
  #     if (app_id == nil)
  #       conditions = "app_id is null"
  #     else
  #       conditions = ["app_id = ?", app_id]
  #     end
  #     begin
  #       APN::Connection.open_for_delivery({:cert => the_cert}) do |conn, sock|
  #         APN::Device.find_each(:conditions => conditions) do |dev|
  #           dev.unsent_notifications.each do |noty|
  #             conn.write(noty.message_for_sending)
  #
  #             # This seems to fix the bug where multiple notifications get
  #             # missed by Apple when sending Push notifications as a worker
  #             # task through Delayed::Job
  #             puts "----NOTIFICATION:\n"
  #             puts noty.message_for_sending.to_yaml
  #             puts "-----------------\n"
  #             puts "============================================"
  #             puts conn.inspect
  #             puts "============================================"
  #             sleep 3
  #             puts "============================================"
  #             puts sock.inspect
  #             puts "============================================"
  #             noty.sent_at = Time.now
  #             noty.save
  #           end
  #         end
  #       end
  #     rescue Exception => e
  #       log_connection_exception(e)
  #     end
  #   # end
  # end
  ######################
  ## testing notifications
  #######################
  def self.response_from_apns(connection)
    timeout = 5
    if IO.select([connection], nil, nil, timeout)
      buf = connection.read(6)
      if buf
        command, error_code, notification_id = buf.unpack('CCN')
        [error_code, notification_id]
      end
    end
  end

  def self.send_notifications_for_cert(the_cert, app_id)
    # unless self.unsent_notifications.nil? || self.unsent_notifications.empty?
    if (app_id == nil)
      conditions = "app_id is null"
    else
      conditions = ["app_id = ?", app_id]
    end
    begin
      APN::Connection.open_for_delivery({:cert => the_cert}) do |conn, sock|
        APN::Device.find_each(:conditions => conditions) do |dev|
          dev.unsent_notifications.each do |noty|
            begin

             # This seems to fix the bug where multiple notifications get
             # missed by Apple when sending Push notifications as a worker
             # task through Delayed::Job
             puts "============================================"
             puts "conn= #{conn.inspect} - sck=#{sock.inspect}"
             puts "============================================"
             #sleep 1
             sleep 0.001
             # puts "=============================="
             # puts "#{noty.id}"
             # puts "******************************"
             #noty.alert = noty.alert.gsub(/["'"]/,'').gsub(/[&]/, '')
             #puts "** encoding changes **"
             conn.write(noty.enhanced_message_for_sending)
             noty.sent_at = Time.now
             noty.save
             puts "-------------Message written----------------"
            rescue Exception => e
              error_code, notif_id = response_from_apns(conn)
              puts "***********************************"
              puts "err_code = #{error_code.inspect} - ntf_id=#{notif_id.inspect}"
              puts "*******#{dev.id}*******#{e.message}********#{noty.id}************"
              #puts "===========#{dev.id}==================="
              #puts "======em=====#{e.message}==================="

              if e.message == "Broken pipe"
                #Write failed (disconnected). Read response.
                #error_code, notif_id = response_from_apns(conn)
                puts "**************Broken Pipe*********************"
                puts "err_code = #{error_code.inspect} - ntf_id=#{notif_id.inspect}"
                puts "***********************************"
                if error_code == 8
                  failed_notification = APN::Notification.find(notif_id)
                  puts failed_notification
                  unless failed_notification.nil?
                    unless failed_notification.device.nil?
                       APN::Device.delete(failed_notification.device.id)
                       # retry sending notifications after invalid token was deleted
                       send_notifications_for_cert(the_cert, app_id)
                     end
                  end
                end
              end
            end
          end
        end
      end
    rescue Exception => e
      log_connection_exception(e)
    end
    # end
  end
  ######################
  ## testing notifications
  #######################
  def send_group_notifications
    if self.cert.nil?
      raise APN::Errors::MissingCertificateError.new
      return
    end
    unless self.unsent_group_notifications.nil? || self.unsent_group_notifications.empty?
      APN::Connection.open_for_delivery({:cert => self.cert}) do |conn, sock|
        unsent_group_notifications.each do |gnoty|
          gnoty.devices.find_each do |device|
            conn.write(gnoty.message_for_sending(device))
          end
          gnoty.sent_at = Time.now
          gnoty.save
        end
      end
    end
  end

  def send_group_notification(gnoty)
    if self.cert.nil?
      raise APN::Errors::MissingCertificateError.new
      return
    end
    unless gnoty.nil?
      APN::Connection.open_for_delivery({:cert => self.cert}) do |conn, sock|
        gnoty.devices.find_each do |device|
          conn.write(gnoty.message_for_sending(device))
        end
        gnoty.sent_at = Time.now
        gnoty.save
      end
    end
  end

  def self.send_group_notifications
    apps = APN::App.all
    apps.each do |app|
      app.send_group_notifications
    end
  end

  # Retrieves a list of APN::Device instnces from Apple using
  # the <tt>devices</tt> method. It then checks to see if the
  # <tt>last_registered_at</tt> date of each APN::Device is
  # before the date that Apple says the device is no longer
  # accepting notifications then the device is deleted. Otherwise
  # it is assumed that the application has been re-installed
  # and is available for notifications.
  #
  # This can be run from the following Rake task:
  #   $ rake apn:feedback:process
  def process_devices
    if self.cert.nil?
      raise APN::Errors::MissingCertificateError.new
      return
    end
    APN::App.process_devices_for_cert(self.cert)
  end # process_devices

  def self.process_devices
    apps = APN::App.all
    apps.each do |app|
      app.process_devices
    end
    if !configatron.apn.cert.blank?
      global_cert = File.read(configatron.apn.cert)
      APN::App.process_devices_for_cert(global_cert)
    end
  end

  def self.process_devices_for_cert(the_cert)
    puts "in APN::App.process_devices_for_cert"
    APN::Feedback.devices(the_cert).each do |device|
      if device.last_registered_at < device.feedback_at
        puts "device #{device.id} -> #{device.last_registered_at} < #{device.feedback_at}"
        device.destroy
      else
        puts "device #{device.id} -> #{device.last_registered_at} not < #{device.feedback_at}"
      end
    end
  end

  protected

  def self.log_connection_exception(ex)
    STDERR.puts ex.message
    raise ex
  end

end
