module Protector
  module Adapters
    module ActiveRecord
      def self.activate!
        ::ActiveRecord::Base.send :include, Protector::Adapters::ActiveRecord::Base
        ::ActiveRecord::Relation.send :include, Protector::Adapters::ActiveRecord::Relation
        ::ActiveRecord::Associations::SingularAssociation.send :include, Protector::Adapters::ActiveRecord::Association
        ::ActiveRecord::Associations::CollectionAssociation.send :include, Protector::Adapters::ActiveRecord::Association
      end

      module Base
        extend ActiveSupport::Concern

        included do
          include Protector::DSL::Base
          include Protector::DSL::Entry

          validate(on: :create) do
            return unless @protector_subject
            errors[:base] << I18n.t('protector.invalid') unless creatable?
          end

          validate(on: :update) do
            return unless @protector_subject
            errors[:base] << I18n.t('protector.invalid') unless updatable?
          end

          before_destroy do
            return true unless @protector_subject
            destroyable?
          end
        end

        module ClassMethods
          def restrict(subject)
            all.restrict(subject)
          end

          def define_method_attribute(name)
            safe_name = name.unpack('h*').first

            if primary_key == name || (primary_key.is_a?(Array) && primary_key.include?(name))
              condition = "true"
            else
              condition = "!@protector_subject || protector_meta.readable?(#{name.inspect})"
            end

            generated_attribute_methods.module_eval <<-STR, __FILE__, __LINE__ + 1
              def __temp__#{safe_name}
                if #{condition}
                  read_attribute(AttrNames::ATTR_#{safe_name}) { |n| missing_attribute(n, caller) }
                else
                  nil
                end
              end
              alias_method #{name.inspect}, :__temp__#{safe_name}
              undef_method :__temp__#{safe_name}
            STR
          end
        end

        def protector_meta
          unless @protector_subject
            raise "Unprotected entity detected: use `restrict` method to protect it."
          end

          self.class.protector_meta.evaluate(
            self.class,
            self.class.column_names,
            @protector_subject,
            self
          )
        end

        def visible?
          protector_meta.relation.where(
            self.class.primary_key => id
          ).any?
        end

        def creatable?
          fields = HashWithIndifferentAccess[changed.map{|x| [x, read_attribute(x)]}]
          protector_meta.creatable?(fields)
        end

        def updatable?
          fields = HashWithIndifferentAccess[changed.map{|x| [x, read_attribute(x)]}]
          protector_meta.updatable?(fields)
        end

        def destroyable?
          protector_meta.destroyable?
        end

        def [](name)
          if !@protector_subject || protector_meta.readable?(name)
            super
          else
            nil
          end
        end

        def association(*args)
          association = super
          association.restrict @protector_subject
          association
        end
      end

      module Relation
        extend ActiveSupport::Concern

        included do
          include Protector::DSL::Base

          alias_method_chain :exec_queries, :protector
        end

        def protector_meta
          @klass.protector_meta.evaluate(@klass, @klass.column_names, @protector_subject)
        end

        def count
          super || 0
        end

        def sum
          super || 0
        end

        def calculate(*args)
          return super unless @protector_subject
          merge(protector_meta.relation).unrestrict.calculate *args
        end

        def exec_queries_with_protector(*args)
          return exec_queries_without_protector unless @protector_subject
          @records = merge(protector_meta.relation).unrestrict.send :exec_queries
        end
      end

      module Association
        extend ActiveSupport::Concern

        included do
          include Protector::DSL::Base

          alias_method_chain :reader, :protector
        end

        def reader_with_protector
          reader_without_protector.restrict(@protector_subject)
        end
      end
    end
  end
end