ANSIBLE_PLAYBOOK ?= ansible-playbook
INVENTORY ?= inventories/production/hosts.yml
ARGS ?=

.PHONY: deploy validate syntax lint reset

deploy:
	$(ANSIBLE_PLAYBOOK) -i $(INVENTORY) playbooks/site.yml $(ARGS)

validate:
	$(ANSIBLE_PLAYBOOK) -i $(INVENTORY) playbooks/validate.yml $(ARGS)

syntax:
	$(ANSIBLE_PLAYBOOK) -i $(INVENTORY) playbooks/site.yml --syntax-check
	$(ANSIBLE_PLAYBOOK) -i $(INVENTORY) playbooks/validate.yml --syntax-check
	$(ANSIBLE_PLAYBOOK) -i $(INVENTORY) playbooks/reset.yml --syntax-check

lint:
	yamllint .
	ansible-lint playbooks/site.yml playbooks/validate.yml playbooks/reset.yml

reset:
	$(ANSIBLE_PLAYBOOK) -i $(INVENTORY) playbooks/reset.yml \
		-e k3s_reset_confirmation=destroy $(ARGS)
